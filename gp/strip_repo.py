#!/usr/bin/env python3
"""
strip_repo.py
~~~~~~~~~~~~~
Cleans up a SoC repository by removing sensitive / heavy / useless files
before sharing it, while preserving everything needed to analyze the
build system (CMake, Bazel, scripts, C sources, headers, etc.).

Operating modes:
  - DEFAULT: safe copy. Recreates the folder tree next to the original,
    copying only the files to keep. The original is never touched.
  - --in-place: operates directly on the original (old behavior).
  - --output-dir PATH: specifies a different output directory
    (default: <root>_stripped/ next to the root).

Cleanup categories (all active by default):
  hdl          Verilog, SystemVerilog, VHDL
  constraints  FPGA / timing constraints (.xdc, .sdc, synthesis .tcl)
  linker       Linker scripts (.ld, .lds)
  config       Configuration files (.cfg, .ini)
  docs         Internal documentation (.doc, .docx, .pdf, .pptx, .xlsx)
  netlist      Netlists and synthesis artifacts (.edf, .edif, .dcp, .bit, .ncd, ...)
  venv         Python virtual environments (venv, .venv, env, .env, ...)
  build_junk   Build artifacts (.o, .a, .elf, .hex, .vcd, .fsdb, ...)

Usage:
    python3 strip_repo.py /path/to/repo                          # safe copy
    python3 strip_repo.py /path/to/repo --output-dir /tmp/out    # explicit output
    python3 strip_repo.py /path/to/repo --in-place               # modify in-place
    python3 strip_repo.py /path/to/repo --only hdl netlist       # only some categories
    python3 strip_repo.py /path/to/repo --skip docs              # all but docs
    python3 strip_repo.py /path/to/repo --dry-run                # preview

Options:
    --dry-run                  Show what would be deleted/copied without touching anything
    --yes / -y                 Skip the interactive confirmation
    --in-place                 Operate on the original (dangerous — asks for extra confirmation)
    --output-dir PATH          Destination directory for the copy (default: <root>_stripped)
    --include-submodules       Include Git submodule files in the copy (default: exclude)
    --only CAT [...]           Activate only the listed categories
    --skip CAT [...]           Deactivate the listed categories
    --extra-ext EXT            Add extra extensions to remove (repeatable)
    --size-warn-threshold MB   Threshold in MB for large-file warnings (default: 5)
    --out-report F             Save the full log (size scan + per-file detail) to a .log file
                               (default: <root>_strip.log if not given with this flag)
    --verbose                  Also print the detailed file-by-file list to screen
    --keep-empty-dirs          Do not remove empty directories (only --in-place)
"""

import argparse
import configparser
import os
import re
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ─────────────────────────────────────────────────────────────
#  CATEGORIES
# ─────────────────────────────────────────────────────────────

CATEGORIES: dict[str, dict] = {
    "hdl": {
        "label": "HDL (Verilog / SystemVerilog / VHDL)",
        "extensions": {
            ".v", ".sv", ".vh", ".svh", ".svi", ".vlib",
            ".vhd", ".vhdl",
        },
    },
    "constraints": {
        "label": "FPGA / timing constraints",
        "extensions": {".xdc", ".sdc", ".ucf", ".pcf", ".lpf"},
        # .tcl is ambiguous — matched by pattern, not by extension
        "filename_patterns": [
            re.compile(r".*synth.*\.tcl$", re.IGNORECASE),
            re.compile(r".*impl.*\.tcl$", re.IGNORECASE),
            re.compile(r".*constraints?\.tcl$", re.IGNORECASE),
            re.compile(r".*timing.*\.tcl$", re.IGNORECASE),
            re.compile(r".*pinout.*\.tcl$", re.IGNORECASE),
        ],
    },
    "linker": {
        "label": "Linker scripts",
        "extensions": {".ld", ".lds"},
    },
    "config": {
        "label": "Configuration files",
        "extensions": {".cfg", ".ini"},
    },
    "docs": {
        "label": "Internal documentation",
        "extensions": {".doc", ".docx", ".pdf", ".pptx", ".xlsx", ".odt", ".odp"},
    },
    "netlist": {
        "label": "Netlist / synthesis / bitstream",
        "extensions": {
            ".edf", ".edif", ".ngc", ".ncd",
            ".dcp", ".xpr",
            ".bit", ".bin", ".mcs", ".mmi",
            ".rpt",
        },
    },
    "venv": {
        "label": "Python virtual environments",
        "extensions": set(),
        "directory_markers": True,
    },
    "build_junk": {
        "label": "Build / simulation artifacts",
        "extensions": {
            ".o", ".obj", ".a", ".lib", ".so", ".dll", ".dylib",
            ".elf", ".hex", ".srec", ".map",
            ".vcd", ".fsdb", ".wlf", ".ghw",
            ".log", ".tmp", ".temp", ".bak",
            ".gds", ".sdf", ".sdc", ".sdb"
        },
    },
}

# Python venv names / markers
VENV_MARKERS = {"pyvenv.cfg"}
VENV_DIR_NAMES = {"venv", ".venv", "env", ".env", "virtualenv", ".virtualenv"}

# Directories always ignored during the scan
SKIP_DIRS = {
    ".git",
    "__pycache__",
    "node_modules",
    ".bazel",
    "bazel-bin",
    "bazel-out",
    "bazel-testlogs",
    "bazel-cache",
    "scratch",
    "analog_ip",
}

# "Known safe" extensions that do not trigger size warnings
# (text/code that can legitimately be large)
KNOWN_TEXT_EXTENSIONS = {
    ".c", ".cpp", ".h", ".hpp", ".py", ".rs", ".go", ".java",
    ".cmake", ".bzl", ".bazel", ".mk", ".sh", ".bash", ".zsh",
    ".json", ".yaml", ".yml", ".toml", ".xml", ".hjson",
    ".md", ".rst", ".txt", ".adoc",
    ".tcl", ".do",
    # HDL (if active we delete them, but they are not "unknown binaries")
    ".v", ".sv", ".vh", ".svh", ".vhd", ".vhdl",
}

# Known binary extensions that are already handled by the categories
# → if they are in the delete-list there is no need to warn
KNOWN_BINARY_MANAGED = set()  # populated at runtime from the active categories


# ─────────────────────────────────────────────────────────────
#  GIT SUBMODULES
# ─────────────────────────────────────────────────────────────

def parse_gitmodules(root: Path) -> list[Path]:
    """
    Reads .gitmodules and returns the relative paths of the submodules.
    Returns an empty list if the file does not exist or cannot be parsed.
    """
    gitmodules = root / ".gitmodules"
    if not gitmodules.exists():
        return []

    paths = []
    try:
        cfg = configparser.RawConfigParser()
        cfg.read(gitmodules, encoding="utf-8")
        for section in cfg.sections():
            if cfg.has_option(section, "path"):
                rel = cfg.get(section, "path").strip()
                paths.append(Path(rel))
    except Exception:
        pass
    return paths


def get_submodule_dirs(root: Path) -> tuple[set[Path], set[Path]]:
    """
    Returns (populated, empty) where each set contains absolute Paths.
    A submodule is "populated" if its directory exists and is not empty.
    """
    populated: set[Path] = set()
    empty: set[Path] = set()

    for rel in parse_gitmodules(root):
        abs_path = root / rel
        if not abs_path.is_dir():
            continue
        # Check whether it is actually populated (has at least one file/dir besides .git)
        try:
            contents = [c for c in abs_path.iterdir() if c.name != ".git"]
            if contents:
                populated.add(abs_path)
            else:
                empty.add(abs_path)
        except OSError:
            empty.add(abs_path)

    return populated, empty


# ─────────────────────────────────────────────────────────────
#  SCAN DATA STRUCTURES
# ─────────────────────────────────────────────────────────────

@dataclass
class FileRecord:
    path: Path
    size: int                    # bytes
    category: Optional[str]      # deletion category, None = keep
    is_venv: bool = False
    warn_large_kept: bool = False      # large file we keep
    warn_large_unknown: bool = False   # large file of unknown type


@dataclass
class ScanResult:
    root: Path
    all_records: list[FileRecord] = field(default_factory=list)
    venv_dirs: list[Path] = field(default_factory=list)
    submodule_dirs_populated: set[Path] = field(default_factory=set)
    submodule_dirs_empty: set[Path] = field(default_factory=set)

    @property
    def to_delete(self) -> list[FileRecord]:
        return [r for r in self.all_records if r.category is not None and not r.is_venv]

    @property
    def to_keep(self) -> list[FileRecord]:
        return [r for r in self.all_records if r.category is None]

    @property
    def large_warnings(self) -> list[FileRecord]:
        return [r for r in self.all_records if r.warn_large_kept or r.warn_large_unknown]


# ─────────────────────────────────────────────────────────────
#  SCAN
# ─────────────────────────────────────────────────────────────

def is_venv_dir(d: Path) -> bool:
    if (d / "pyvenv.cfg").exists():
        return True
    if d.name.lower() in VENV_DIR_NAMES:
        if (d / "bin" / "activate").exists() or (d / "Scripts" / "activate").exists():
            return True
    return False


def _classify_file(
    fpath: Path,
    fname: str,
    active_categories: set[str],
    all_extensions: set[str],
    filename_patterns: list,
    size_warn_bytes: int,
) -> FileRecord:
    """Classifies a single file and builds its FileRecord."""
    try:
        size = fpath.stat().st_size
    except OSError:
        size = 0

    suffix = Path(fname).suffix.lower()
    category: Optional[str] = None

    # Determine the deletion category
    for cat_name in active_categories:
        if cat_name == "venv":
            continue
        cat = CATEGORIES.get(cat_name, {})
        exts = cat.get("extensions", set())
        patterns = cat.get("filename_patterns", [])
        if suffix in exts:
            category = cat_name
            break
        if any(p.match(fname) for p in patterns):
            category = cat_name
            break

    # Size warning
    warn_large_kept = False
    warn_large_unknown = False

    if size >= size_warn_bytes:
        if category is not None:
            # Large file but it gets deleted → no warning
            pass
        else:
            # File we keep — is it large?
            if suffix not in KNOWN_TEXT_EXTENSIONS:
                # Binary or unknown extension
                warn_large_unknown = True
            else:
                warn_large_kept = True

    return FileRecord(
        path=fpath,
        size=size,
        category=category,
        warn_large_kept=warn_large_kept,
        warn_large_unknown=warn_large_unknown,
    )


def scan(
    root: Path,
    active_categories: set[str],
    extra_extensions: set[str],
    size_warn_bytes: int,
    include_submodules: bool,
) -> ScanResult:
    """Full scan of the repo."""
    result = ScanResult(root=root)

    # Submodules
    result.submodule_dirs_populated, result.submodule_dirs_empty = get_submodule_dirs(root)

    # Active extensions
    all_extensions = extra_extensions.copy()
    filename_patterns = []

    for cat_name in active_categories:
        if cat_name == "venv":
            continue
        cat = CATEGORIES.get(cat_name, {})
        all_extensions |= cat.get("extensions", set())
        filename_patterns.extend(cat.get("filename_patterns", []))

    check_venv = "venv" in active_categories

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        d = Path(dirpath)

        # Skip protected directories
        dirnames[:] = [dn for dn in dirnames if dn not in SKIP_DIRS]

        # Submodule handling
        if not include_submodules:
            new_dirnames = []
            for dn in dirnames:
                child = d / dn
                if child in result.submodule_dirs_populated or child in result.submodule_dirs_empty:
                    # Submodule: skip
                    pass
                else:
                    new_dirnames.append(dn)
            dirnames[:] = new_dirnames
        else:
            # Include submodules but skip their internal .git
            dirnames[:] = [dn for dn in dirnames if dn != ".git" or d == root]

        # Check whether it is a venv
        if check_venv and d != root and is_venv_dir(d):
            result.venv_dirs.append(d)
            dirnames.clear()
            continue

        for fname in filenames:
            fpath = d / fname
            rec = _classify_file(
                fpath, fname,
                active_categories, all_extensions, filename_patterns,
                size_warn_bytes,
            )
            result.all_records.append(rec)

    # Sort by decreasing size (for the report)
    result.all_records.sort(key=lambda r: r.size, reverse=True)
    result.venv_dirs.sort()
    return result


# ─────────────────────────────────────────────────────────────
#  OUTPUT / REPORT
# ─────────────────────────────────────────────────────────────

def human_size(nbytes: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


def dir_total_size(d: Path) -> int:
    total = 0
    try:
        for f in d.rglob("*"):
            if f.is_file():
                try:
                    total += f.stat().st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total


def _status_label(rec: FileRecord) -> str:
    if rec.category is not None:
        return f"DELETE   ({rec.category})"
    if rec.warn_large_unknown:
        return "KEEP     ⚠  unknown type"
    if rec.warn_large_kept:
        return "KEEP     ⚠  large file"
    return "KEEP"


def _build_size_report_lines(result: ScanResult) -> list[str]:
    """Builds the lines of the size report (without printing them)."""
    SEP = "─" * 100
    lines = [
        "",
        SEP,
        "  SIZE SCAN — all files ordered from largest to smallest",
        SEP,
        f"  {'SIZE':>10}  {'STATUS':<35}  PATH",
        SEP,
    ]
    for rec in result.all_records:
        label = _status_label(rec)
        rel = rec.path.relative_to(result.root)
        lines.append(f"  {human_size(rec.size):>10}  {label:<35}  {rel}")
    for d in result.venv_dirs:
        sz = dir_total_size(d)
        rel = d.relative_to(result.root)
        lines.append(f"  {human_size(sz):>10}  {'DELETE   (venv)':<35}  {rel}/")
    for d in sorted(result.submodule_dirs_populated):
        sz = dir_total_size(d)
        rel = d.relative_to(result.root)
        lines.append(f"  {human_size(sz):>10}  {'EXCLUDED (submodule)':<35}  {rel}/")
    for d in sorted(result.submodule_dirs_empty):
        rel = d.relative_to(result.root)
        lines.append(f"  {'0 B':>10}  {'EXCLUDED (empty submodule)':<35}  {rel}/")
    lines.append(SEP)
    return lines


def print_size_report(result: ScanResult, verbose: bool):
    """
    With --verbose prints the full list to screen.
    Without the flag prints only the WARNINGs (if any).
    The full log is always written to file by save_log().
    """
    if verbose:
        for line in _build_size_report_lines(result):
            print(line)
        print()
    else:
        warn_lines = [l for l in _build_size_report_lines(result) if "⚠" in l]
        if warn_lines:
            SEP = "─" * 100
            print(f"\n{SEP}")
            print("  SIZES — only files with warnings  (use --verbose for the full list)")
            print(SEP)
            for l in warn_lines:
                print(l)
            print(f"{SEP}")


def print_summary(result: ScanResult, active_categories: set[str], mode: str):
    to_delete = result.to_delete
    to_keep = result.to_keep
    warnings = result.large_warnings

    total_delete = sum(r.size for r in to_delete)
    total_venv = sum(dir_total_size(d) for d in result.venv_dirs)
    total_keep = sum(r.size for r in to_keep)

    SEP = "=" * 70
    print(f"\n{SEP}")
    print(f"  SUMMARY — {result.root}")
    print(f"{SEP}")
    print(f"  Mode:                 {mode}")
    print(f"  Active categories:    {', '.join(sorted(active_categories))}")
    print()
    print(f"  Files to delete:      {len(to_delete):>6}  ({human_size(total_delete)})")
    if result.venv_dirs:
        print(f"  Venvs to delete:      {len(result.venv_dirs):>6}  ({human_size(total_venv)})")
    print(f"  Files to keep:        {len(to_keep):>6}  ({human_size(total_keep)})")
    if result.submodule_dirs_populated or result.submodule_dirs_empty:
        tot_sub = len(result.submodule_dirs_populated) + len(result.submodule_dirs_empty)
        print(f"  Excluded submodules:  {tot_sub:>6}")
    if warnings:
        n_unk = sum(1 for r in warnings if r.warn_large_unknown)
        n_kept = sum(1 for r in warnings if r.warn_large_kept)
        print()
        print(f"  ⚠  Size WARNINGs:")
        if n_unk:
            print(f"      {n_unk} file(s) of unrecognized type and large size")
        if n_kept:
            print(f"      {n_kept} kept file(s) of large size (large text/code)")
    print(f"{SEP}\n")

    # By extension
    by_ext: dict[str, list] = defaultdict(list)
    for r in to_delete:
        by_ext[r.path.suffix.lower()].append(r)
    if by_ext:
        print("  Deleted by extension:")
        for ext in sorted(by_ext, key=lambda e: -sum(r.size for r in by_ext[e])):
            recs = by_ext[ext]
            size = sum(r.size for r in recs)
            print(f"    {ext:8s}  →  {len(recs):5d} files  ({human_size(size)})")
        print()

    # By category
    print("  Deleted by category:")
    for cat_name in sorted(active_categories):
        cat = CATEGORIES.get(cat_name, {})
        if cat_name == "venv":
            if result.venv_dirs:
                print(f"    {cat.get('label', cat_name):40s}  {len(result.venv_dirs):5d} directories")
            continue
        recs = [r for r in to_delete if r.category == cat_name]
        if recs:
            print(f"    {cat.get('label', cat_name):40s}  {len(recs):5d} files")
    print()

    # Detailed warnings
    if warnings:
        print("  ⚠  Files with size warning (verify manually):")
        for r in sorted(warnings, key=lambda r: -r.size):
            rel = r.path.relative_to(result.root)
            tag = "unknown type" if r.warn_large_unknown else "large text/code"
            print(f"    {human_size(r.size):>10}  [{tag}]  {rel}")
        print()


def save_log(result: ScanResult, filepath: str):
    """
    Writes the full log to file: size scan + per-section detail.
    Always called (default path or explicit via --out-report).
    """
    to_delete = result.to_delete
    to_keep = result.to_keep
    warnings = result.large_warnings

    with open(filepath, "w", encoding="utf-8") as f:
        f.write("# strip_repo.py — full log\n")
        f.write(f"# Root: {result.root}\n\n")

        # Full size scan
        for line in _build_size_report_lines(result):
            f.write(line + "\n")
        f.write("\n")

        f.write("# ── FILES TO DELETE ──────────────────────────────────\n")
        for r in sorted(to_delete, key=lambda r: r.path):
            rel = r.path.relative_to(result.root)
            f.write(f"{human_size(r.size):>10}  [{r.category}]  {rel}\n")

        if result.venv_dirs:
            f.write("\n# ── VENVS TO DELETE ──────────────────────────────────\n")
            for d in result.venv_dirs:
                rel = d.relative_to(result.root)
                f.write(f"{human_size(dir_total_size(d)):>10}  [venv]  {rel}/\n")

        f.write("\n# ── KEPT FILES ───────────────────────────────────────\n")
        for r in sorted(to_keep, key=lambda r: -r.size):
            rel = r.path.relative_to(result.root)
            warn = "  ⚠" if (r.warn_large_kept or r.warn_large_unknown) else ""
            f.write(f"{human_size(r.size):>10}  {rel}{warn}\n")

        if warnings:
            f.write("\n# ── SIZE WARNINGS ────────────────────────────────────\n")
            for r in sorted(warnings, key=lambda r: -r.size):
                rel = r.path.relative_to(result.root)
                tag = "unknown type" if r.warn_large_unknown else "large text"
                f.write(f"{human_size(r.size):>10}  [{tag}]  {rel}\n")

        if result.submodule_dirs_populated or result.submodule_dirs_empty:
            f.write("\n# ── EXCLUDED SUBMODULES ──────────────────────────────\n")
            for d in sorted(result.submodule_dirs_populated | result.submodule_dirs_empty):
                rel = d.relative_to(result.root)
                populated = d in result.submodule_dirs_populated
                f.write(f"{'populated' if populated else 'empty':>10}  {rel}/\n")

    print(f"  Log saved to: {filepath}")

def copy_selective(result: ScanResult, output_dir: Path, dry_run: bool) -> tuple[int, int]:
    """
    Recreates output_dir copying only the files to keep.
    Returns (copied, errors).
    """
    to_keep = result.to_keep
    ok = err = 0

    if not dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    for rec in to_keep:
        rel = rec.path.relative_to(result.root)
        dest = output_dir / rel
        if dry_run:
            ok += 1
            continue
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(rec.path, dest)
            ok += 1
        except OSError as e:
            print(f"  COPY ERROR: {rel} — {e}", file=sys.stderr)
            err += 1

    return ok, err


# ─────────────────────────────────────────────────────────────
#  IN-PLACE DELETION
# ─────────────────────────────────────────────────────────────

def delete_files(files: list[FileRecord]) -> tuple[int, int]:
    ok = err = 0
    for rec in files:
        try:
            rec.path.unlink()
            ok += 1
        except OSError as e:
            print(f"  ERROR: {rec.path} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def delete_venv_dirs(venv_dirs: list[Path]) -> tuple[int, int]:
    ok = err = 0
    for d in venv_dirs:
        try:
            shutil.rmtree(d)
            ok += 1
        except OSError as e:
            print(f"  rmtree ERROR: {d} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def prune_empty_dirs(root: Path, dry_run: bool = False) -> list[Path]:
    removed = []
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        d = Path(dirpath)
        if d == root:
            continue
        if d.name in SKIP_DIRS:
            continue
        try:
            remaining = list(d.iterdir())
        except OSError:
            continue
        if not remaining:
            removed.append(d)
            if not dry_run:
                try:
                    d.rmdir()
                except OSError as e:
                    print(f"  rmdir ERROR: {d} — {e}", file=sys.stderr)
    return removed


def find_dirs_that_would_be_empty(result: ScanResult) -> list[Path]:
    deleted_set = {r.path for r in result.to_delete}
    would_remove: set[Path] = set(result.venv_dirs)
    root = result.root

    all_dirs: set[Path] = set()
    for r in result.to_delete:
        p = r.path.parent
        while p != root and p != p.parent:
            all_dirs.add(p)
            p = p.parent
    for v in result.venv_dirs:
        p = v.parent
        while p != root and p != p.parent:
            all_dirs.add(p)
            p = p.parent

    for d in sorted(all_dirs, key=lambda x: len(x.parts), reverse=True):
        if d.name in SKIP_DIRS:
            continue
        try:
            children = list(d.iterdir())
        except OSError:
            continue
        all_gone = all((c in deleted_set) or (c in would_remove) for c in children)
        if all_gone and children:
            would_remove.add(d)

    return sorted(would_remove - set(result.venv_dirs))


# ─────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────

def main():
    all_cat_names = list(CATEGORIES.keys())

    parser = argparse.ArgumentParser(
        description="Cleans up a SoC repository by removing sensitive, heavy "
                    "or useless files before sharing it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Available categories: " + ", ".join(all_cat_names),
    )
    parser.add_argument(
        "root", type=Path,
        help="Root directory of the project",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be done without touching anything",
    )
    parser.add_argument(
        "--yes", "-y", action="store_true",
        help="Skip the interactive confirmation",
    )
    parser.add_argument(
        "--in-place", action="store_true",
        help="Modify the original repo (dangerous — requires extra confirmation)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Output directory for the copy (default: <root>_stripped)",
    )
    parser.add_argument(
        "--include-submodules", action="store_true",
        help="Include Git submodule files in the copy",
    )
    parser.add_argument(
        "--only", nargs="+", metavar="CAT", choices=all_cat_names,
        help="Activate only the listed categories",
    )
    parser.add_argument(
        "--skip", nargs="+", metavar="CAT", choices=all_cat_names,
        help="Deactivate the listed categories",
    )
    parser.add_argument(
        "--extra-ext", action="append", default=[],
        help="Extra extensions to remove (repeatable)",
    )
    parser.add_argument(
        "--size-warn-threshold", type=float, default=5.0, metavar="MB",
        help="Threshold in MB for large-file warnings (default: 5)",
    )
    parser.add_argument(
        "--out-report", type=str, default=None,
        help="Path of the .log file (default: <root>_strip.log next to the root)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Print the full file-by-file list to screen (default: summary only)",
    )
    parser.add_argument(
        "--keep-empty-dirs", action="store_true",
        help="Do not remove empty directories (only --in-place)",
    )

    args = parser.parse_args()

    # Root validation
    root = args.root.resolve()
    if not root.is_dir():
        print(f"Error: '{root}' is not a valid directory.", file=sys.stderr)
        sys.exit(1)

    # Active categories
    if args.only:
        active = set(args.only)
    else:
        active = set(all_cat_names)
    if args.skip:
        active -= set(args.skip)
    if not active:
        print("Error: no active category.", file=sys.stderr)
        sys.exit(1)

    # Extra extensions
    extra_ext = set()
    for ext in args.extra_ext:
        if not ext.startswith("."):
            ext = "." + ext
        extra_ext.add(ext.lower())

    # Operating mode
    in_place = args.in_place
    if in_place:
        mode_label = "IN-PLACE (modify original)"
        output_dir = None
    else:
        if args.output_dir:
            output_dir = args.output_dir.resolve()
        else:
            output_dir = root.parent / (root.name + "_stripped")
        mode_label = f"SAFE COPY → {output_dir}"

    size_warn_bytes = int(args.size_warn_threshold * 1024 * 1024)

    # ── SCAN ───────────────────────────────────────────────────
    print(f"\n  Scanning: {root} ...")
    result = scan(root, active, extra_ext, size_warn_bytes, args.include_submodules)

    if not result.all_records and not result.venv_dirs:
        print("\n  No file found. Nothing to do.\n")
        sys.exit(0)

    # ── SIZE REPORT (always, all files) ────────────────────────
    print_size_report(result, args.verbose)

    # ── SUMMARY ────────────────────────────────────────────────
    print_summary(result, active, mode_label)

    # ── LOG TO FILE (always) ─────────────────────────
    log_path = args.out_report if args.out_report else str(root.parent / (root.name + '_strip.log'))
    save_log(result, log_path)

    # ── DRY-RUN ────────────────────────────────────────────────
    if args.dry_run:
        if in_place:
            print("  [DRY-RUN] No file deleted.")
            empty_dirs = find_dirs_that_would_be_empty(result)
            if not args.keep_empty_dirs and empty_dirs:
                print(f"\n  Directories that would be removed (left empty): {len(empty_dirs)}")
                for d in empty_dirs:
                    print(f"    {d.relative_to(root)}/")
        else:
            print(f"  [DRY-RUN] Would copy {len(result.to_keep)} files to:")
            print(f"    {output_dir}")
        print()
        sys.exit(0)

    # ── CONFIRMATION ───────────────────────────────────────────
    if not args.yes:
        if in_place:
            # Double confirmation for the destructive operation
            print("  ⚠  WARNING: IN-PLACE mode. The original repo will be modified.")
            answer = input(
                f"  Confirm deletion of {len(result.to_delete)} files"
                + (f" and {len(result.venv_dirs)} venvs" if result.venv_dirs else "")
                + " FROM THE ORIGINAL REPO? [type 'YES' in uppercase to confirm] "
            ).strip()
            if answer != "YES":
                print("  Operation cancelled.\n")
                sys.exit(0)
        else:
            if output_dir.exists():
                print(f"  ⚠  The output directory already exists: {output_dir}")
                answer = input(
                    f"  Overwrite by copying {len(result.to_keep)} files to keep? [y/N] "
                ).strip().lower()
            else:
                answer = input(
                    f"  Copy {len(result.to_keep)} files to '{output_dir}'? [y/N] "
                ).strip().lower()
            if answer not in ("y", "yes"):
                print("  Operation cancelled.\n")
                sys.exit(0)

    # ── EXECUTION ──────────────────────────────────────────────
    if in_place:
        f_ok, f_err = delete_files(result.to_delete)
        print(f"\n  Files deleted: {f_ok}, errors: {f_err}")

        if result.venv_dirs:
            v_ok, v_err = delete_venv_dirs(result.venv_dirs)
            print(f"  Venvs removed: {v_ok}, errors: {v_err}")

        if not args.keep_empty_dirs:
            pruned = prune_empty_dirs(root)
            if pruned:
                print(f"  Empty directories removed: {len(pruned)}")
                for d in pruned[:15]:
                    print(f"    {d.relative_to(root)}/")
                if len(pruned) > 15:
                    print(f"    ... and {len(pruned) - 15} more")
            else:
                print("  No directory left empty.")
    else:
        print(f"\n  Selective copy in progress → {output_dir} ...")
        c_ok, c_err = copy_selective(result, output_dir, dry_run=False)
        print(f"  Files copied: {c_ok}, errors: {c_err}")
        if result.large_warnings:
            print(f"\n  ⚠  {len(result.large_warnings)} file(s) with size warning in the copy.")
            print(f"     See the log for details: {log_path}")

    print()


if __name__ == "__main__":
    main()

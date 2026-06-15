#!/usr/bin/env python3
"""
strip_hdl.py
~~~~~~~~~~~~
Finds and removes Verilog / SystemVerilog / VHDL files from a project,
preserving everything else (BUILD, CMake, scripts, C, Python, etc.).
After deletion, recursively removes the directories left empty.

Usage:
    python3 strip_hdl.py /path/to/repo

Options:
    --dry-run         Only show what would be deleted, without touching anything
    --yes             Skip the interactive confirmation
    --extra-ext EXT   Add extra extensions to remove (repeatable)
    --out-report F    Save the report to a text file
    --keep-empty-dirs Do not remove the directories left empty
"""

import argparse
import os
import sys
from pathlib import Path
from collections import defaultdict

# Verilog / SystemVerilog / VHDL extensions (case-insensitive)
DEFAULT_EXTENSIONS = {
    # Verilog / SystemVerilog
    ".v",
    ".sv",
    ".vh",
    ".svh",
    ".svi",        # SystemVerilog include (used in some flows)
    ".vlib",       # Verilog library file
    # VHDL
    ".vhd",
    ".vhdl",
}

# Directories to always ignore (avoids descending into .git, build artifacts, etc.)
SKIP_DIRS = {
    ".git",
    "__pycache__",
    "node_modules",
    ".bazel",
    "bazel-bin",
    "bazel-out",
    "bazel-testlogs",
    "bazel-cache",
}


def find_verilog_files(root: Path, extensions: set[str]) -> list[Path]:
    """Scans recursively and returns the files with the given extensions."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune in-place the directories we should not visit
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fname in filenames:
            if Path(fname).suffix.lower() in extensions:
                found.append(Path(dirpath) / fname)
    found.sort()
    return found


def human_size(nbytes: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


def print_summary(files: list[Path], root: Path, extensions: set[str]):
    """Prints a summary grouped by extension and directory."""
    by_ext = defaultdict(list)
    total_size = 0

    for f in files:
        by_ext[f.suffix.lower()].append(f)
        try:
            total_size += f.stat().st_size
        except OSError:
            pass

    print(f"\n{'='*60}")
    print(f"  SCAN SUMMARY — {root}")
    print(f"{'='*60}")
    print(f"  Files found:   {len(files)}")
    print(f"  Size:          {human_size(total_size)}")
    print(f"  Extensions:    {', '.join(sorted(extensions))}")
    print(f"{'='*60}\n")

    # Breakdown by extension
    print("  By extension:")
    for ext in sorted(by_ext):
        count = len(by_ext[ext])
        size = sum(f.stat().st_size for f in by_ext[ext] if f.exists())
        print(f"    {ext:6s}  →  {count:5d} files  ({human_size(size)})")

    # Top 10 directories with the most files
    by_dir = defaultdict(int)
    for f in files:
        rel = f.relative_to(root)
        top = rel.parts[0] if len(rel.parts) > 1 else "."
        by_dir[top] += 1

    print("\n  Main directories:")
    for d, count in sorted(by_dir.items(), key=lambda x: -x[1])[:10]:
        print(f"    {d:30s}  {count:5d} files")
    print()


def save_report(files: list[Path], root: Path, filepath: str):
    """Saves the full list of files to a text file."""
    with open(filepath, "w") as f:
        for p in files:
            f.write(str(p.relative_to(root)) + "\n")
    print(f"  Report saved to: {filepath}")


def delete_files(files: list[Path]) -> tuple[int, int]:
    """Deletes the files. Returns (successes, errors)."""
    ok, err = 0, 0
    for f in files:
        try:
            f.unlink()
            ok += 1
        except OSError as e:
            print(f"  ERROR: {f} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def prune_empty_dirs(root: Path, dry_run: bool = False) -> list[Path]:
    """Recursively removes empty directories from the bottom up.

    Works bottom-up: if a subdirectory becomes empty after removing the
    HDL files, it gets deleted. If that also empties the parent
    directory, it gets deleted in turn, and so on up to the root
    (which is never removed).

    Returns the list of removed directories (or those that would be
    removed in dry-run).
    """
    removed = []
    # os.walk bottom-up: visit the leaves first
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        d = Path(dirpath)
        # Never remove the root itself
        if d == root:
            continue
        # Skip protected directories
        if d.name in SKIP_DIRS:
            continue
        # Check whether the directory is actually empty now
        # (children may have been removed in previous iterations)
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
                    print(f"  ERROR rmdir: {d} — {e}", file=sys.stderr)

    return removed


def find_dirs_that_would_be_empty(
    files_to_delete: list[Path], root: Path
) -> list[Path]:
    """Simulates which directories would be left empty after removing the files.

    Used in dry-run mode to give a preview without touching anything.
    """
    # Collect all the project directories and their contents
    deleted_set = set(files_to_delete)
    would_remove: set[Path] = set()

    # Bottom-up: start from the leaves
    all_dirs = set()
    for f in files_to_delete:
        p = f.parent
        while p != root and p != p.parent:
            all_dirs.add(p)
            p = p.parent

    # Sort by decreasing depth (leaves first)
    for d in sorted(all_dirs, key=lambda x: len(x.parts), reverse=True):
        if d.name in SKIP_DIRS:
            continue
        try:
            children = list(d.iterdir())
        except OSError:
            continue
        # A directory is "empty" if each of its children is a file to delete
        # or a subdirectory that would be removed
        all_gone = all(
            (c in deleted_set) or (c in would_remove)
            for c in children
        )
        if all_gone and children:  # do not report already-empty dirs
            would_remove.add(d)

    return sorted(would_remove)


def main():
    parser = argparse.ArgumentParser(
        description="Removes Verilog/SystemVerilog/VHDL files from a project "
                    "and cleans up the directories left empty"
    )
    parser.add_argument(
        "root",
        type=Path,
        help="Root directory of the project"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be deleted without removing anything"
    )
    parser.add_argument(
        "--yes", "-y",
        action="store_true",
        help="Skip the interactive confirmation"
    )
    parser.add_argument(
        "--extra-ext",
        action="append",
        default=[],
        help="Extra extensions to remove (e.g. --extra-ext .tcl)"
    )
    parser.add_argument(
        "--out-report",
        type=str,
        default=None,
        help="Save the list of found files to a text file"
    )
    parser.add_argument(
        "--keep-empty-dirs",
        action="store_true",
        help="Do not remove the directories left empty after deletion"
    )

    args = parser.parse_args()

    if not args.root.is_dir():
        print(f"Error: '{args.root}' is not a valid directory.", file=sys.stderr)
        sys.exit(1)

    # Build the extension set
    extensions = DEFAULT_EXTENSIONS.copy()
    for ext in args.extra_ext:
        if not ext.startswith("."):
            ext = "." + ext
        extensions.add(ext.lower())

    # Scan
    print(f"\n  Scanning: {args.root.resolve()} ...")
    files = find_verilog_files(args.root, extensions)

    if not files:
        print("\n  No HDL file (Verilog/SV/VHDL) found. Nothing to do.\n")
        sys.exit(0)

    print_summary(files, args.root, extensions)

    # Optional report
    if args.out_report:
        save_report(files, args.root, args.out_report)

    # Full list (shows the first 30 + ellipsis)
    print("  Files that will be deleted:")
    show_max = 30
    for f in files[:show_max]:
        print(f"    {f.relative_to(args.root)}")
    if len(files) > show_max:
        print(f"    ... and {len(files) - show_max} more files")
        print(f"    (use --out-report for the full list)")
    print()

    if args.dry_run:
        print("  [DRY-RUN] No file deleted.")
        if not args.keep_empty_dirs:
            # Simulate the cleanup: count the dirs that would contain only HDL files
            empty_dirs = find_dirs_that_would_be_empty(files, args.root)
            if empty_dirs:
                print(f"\n  Directories that would be removed (left empty): {len(empty_dirs)}")
                for d in empty_dirs[:20]:
                    print(f"    {d.relative_to(args.root)}/")
                if len(empty_dirs) > 20:
                    print(f"    ... and {len(empty_dirs) - 20} more")
        print()
        sys.exit(0)

    # Confirmation
    if not args.yes:
        answer = input(
            f"  Confirm deletion of {len(files)} files? [y/N] "
        ).strip().lower()
        if answer not in ("y", "yes"):
            print("  Operation cancelled.\n")
            sys.exit(0)

    # Delete files
    ok, err = delete_files(files)
    print(f"\n  Files: {ok} deleted, {err} errors.")

    # Clean up empty directories
    if not args.keep_empty_dirs:
        pruned = prune_empty_dirs(args.root)
        if pruned:
            print(f"  Empty directories removed: {len(pruned)}")
            for d in pruned[:15]:
                print(f"    {d.relative_to(args.root)}/")
            if len(pruned) > 15:
                print(f"    ... and {len(pruned) - 15} more")
        else:
            print("  No directory left empty.")
    print()


if __name__ == "__main__":
    main()

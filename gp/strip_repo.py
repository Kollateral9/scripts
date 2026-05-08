#!/usr/bin/env python3
"""
strip_repo.py
~~~~~~~~~~~~~
Pulisce un repository SoC rimuovendo file sensibili / pesanti / inutili
prima di condividerlo, preservando tutto ciò che serve per analizzare
il build system (CMake, Bazel, script, sorgenti C, header, ecc.).

Modalità di operazione:
  - DEFAULT: copia sicura. Ricrea il folder tree accanto all'originale,
    copiando solo i file da tenere. L'originale non viene mai toccato.
  - --in-place: opera direttamente sull'originale (comportamento vecchio).
  - --output-dir PATH: specifica una directory di output diversa
    (default: <root>_stripped/ accanto alla root).

Categorie di pulizia (tutte attive di default):
  hdl          Verilog, SystemVerilog, VHDL
  constraints  Constraint FPGA / timing (.xdc, .sdc, .tcl di sintesi)
  linker       Linker script (.ld, .lds)
  config       File di configurazione (.cfg, .ini)
  docs         Documentazione interna (.doc, .docx, .pdf, .pptx, .xlsx)
  netlist      Netlist e artefatti di sintesi (.edf, .edif, .dcp, .bit, .ncd, ...)
  venv         Ambienti virtuali Python (venv, .venv, env, .env, ...)
  build_junk   Artefatti di compilazione (.o, .a, .elf, .hex, .vcd, .fsdb, ...)

Uso:
    python3 strip_repo.py /percorso/alla/repo                          # copia sicura
    python3 strip_repo.py /percorso/alla/repo --output-dir /tmp/out    # output esplicito
    python3 strip_repo.py /percorso/alla/repo --in-place               # modifica in-place
    python3 strip_repo.py /percorso/alla/repo --only hdl netlist       # solo alcune categorie
    python3 strip_repo.py /percorso/alla/repo --skip docs              # tutte tranne docs
    python3 strip_repo.py /percorso/alla/repo --dry-run                # anteprima

Opzioni:
    --dry-run                  Mostra cosa verrebbe eliminato/copiato senza toccare nulla
    --yes / -y                 Salta la conferma interattiva
    --in-place                 Opera sull'originale (pericoloso — chiede conferma extra)
    --output-dir PATH          Directory di destinazione per la copia (default: <root>_stripped)
    --include-submodules       Includi i file dei submoduli Git nella copia (default: escludi)
    --only CAT [...]           Attiva solo le categorie elencate
    --skip CAT [...]           Disattiva le categorie elencate
    --extra-ext EXT            Aggiunge estensioni extra da rimuovere (ripetibile)
    --size-warn-threshold MB   Soglia in MB per i warning sui file grandi (default: 5)
    --out-report F             Salva il log completo (size scan + dettaglio file) in un file .log
                               (default: <root>_strip.log se non specificato con questo flag)
    --verbose                  Stampa a schermo anche la lista dettagliata file per file
    --keep-empty-dirs          Non rimuovere le cartelle vuote (solo --in-place)
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
#  CATEGORIE
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
        "label": "Constraint FPGA / timing",
        "extensions": {".xdc", ".sdc", ".ucf", ".pcf", ".lpf"},
        # .tcl è ambiguo — cercato per pattern, non per estensione
        "filename_patterns": [
            re.compile(r".*synth.*\.tcl$", re.IGNORECASE),
            re.compile(r".*impl.*\.tcl$", re.IGNORECASE),
            re.compile(r".*constraints?\.tcl$", re.IGNORECASE),
            re.compile(r".*timing.*\.tcl$", re.IGNORECASE),
            re.compile(r".*pinout.*\.tcl$", re.IGNORECASE),
        ],
    },
    "linker": {
        "label": "Linker script",
        "extensions": {".ld", ".lds"},
    },
    "config": {
        "label": "File di configurazione",
        "extensions": {".cfg", ".ini"},
    },
    "docs": {
        "label": "Documentazione interna",
        "extensions": {".doc", ".docx", ".pdf", ".pptx", ".xlsx", ".odt", ".odp"},
    },
    "netlist": {
        "label": "Netlist / sintesi / bitstream",
        "extensions": {
            ".edf", ".edif", ".ngc", ".ncd",
            ".dcp", ".xpr",
            ".bit", ".bin", ".mcs", ".mmi",
            ".rpt",
        },
    },
    "venv": {
        "label": "Ambienti virtuali Python",
        "extensions": set(),
        "directory_markers": True,
    },
    "build_junk": {
        "label": "Artefatti di compilazione / simulazione",
        "extensions": {
            ".o", ".obj", ".a", ".lib", ".so", ".dll", ".dylib",
            ".elf", ".hex", ".srec", ".map",
            ".vcd", ".fsdb", ".wlf", ".ghw",
            ".log", ".tmp", ".temp", ".bak",
            ".gds", ".sdf", ".sdc", ".sdb"
        },
    },
}

# Nomi/marker di venv Python
VENV_MARKERS = {"pyvenv.cfg"}
VENV_DIR_NAMES = {"venv", ".venv", "env", ".env", "virtualenv", ".virtualenv"}

# Directory sempre ignorate durante la scansione
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

# Estensioni "note sicure" che non generano warning di dimensione
# (testo/codice che può essere legittimamente grande)
KNOWN_TEXT_EXTENSIONS = {
    ".c", ".cpp", ".h", ".hpp", ".py", ".rs", ".go", ".java",
    ".cmake", ".bzl", ".bazel", ".mk", ".sh", ".bash", ".zsh",
    ".json", ".yaml", ".yml", ".toml", ".xml", ".hjson",
    ".md", ".rst", ".txt", ".adoc",
    ".tcl", ".do",
    # HDL (se attivi li eliminiamo, ma non sono "binary sconosciuti")
    ".v", ".sv", ".vh", ".svh", ".vhd", ".vhdl",
}

# Estensioni binarie note che però vengono già gestite dalle categorie
# → se sono nella delete-list non serve avvertire
KNOWN_BINARY_MANAGED = set()  # popolato a runtime dalle categorie attive


# ─────────────────────────────────────────────────────────────
#  SUBMODULI GIT
# ─────────────────────────────────────────────────────────────

def parse_gitmodules(root: Path) -> list[Path]:
    """
    Legge .gitmodules e restituisce i percorsi relativi dei submoduli.
    Restituisce lista vuota se il file non esiste o non è parsabile.
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
    Ritorna (popolati, vuoti) dove ogni set contiene Path assoluti.
    Un submodulo è "popolato" se la sua directory esiste e non è vuota.
    """
    populated: set[Path] = set()
    empty: set[Path] = set()

    for rel in parse_gitmodules(root):
        abs_path = root / rel
        if not abs_path.is_dir():
            continue
        # Controlla se è davvero popolato (ha almeno un file/dir oltre a .git)
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
#  STRUTTURA DATI SCAN
# ─────────────────────────────────────────────────────────────

@dataclass
class FileRecord:
    path: Path
    size: int                    # byte
    category: Optional[str]      # categoria di eliminazione, None = da tenere
    is_venv: bool = False
    warn_large_kept: bool = False      # file grande che teniamo
    warn_large_unknown: bool = False   # file grande con tipo ignoto


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
#  SCANSIONE
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
    """Classifica un singolo file e costruisce il suo FileRecord."""
    try:
        size = fpath.stat().st_size
    except OSError:
        size = 0

    suffix = Path(fname).suffix.lower()
    category: Optional[str] = None

    # Determina categoria di eliminazione
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

    # Warning dimensione
    warn_large_kept = False
    warn_large_unknown = False

    if size >= size_warn_bytes:
        if category is not None:
            # File grande ma viene eliminato → nessun warning
            pass
        else:
            # File che teniamo — è grande?
            if suffix not in KNOWN_TEXT_EXTENSIONS:
                # Estensione binaria o sconosciuta
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
    """Scansione completa della repo."""
    result = ScanResult(root=root)

    # Submoduli
    result.submodule_dirs_populated, result.submodule_dirs_empty = get_submodule_dirs(root)

    # Estensioni attive
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

        # Salta directory protette
        dirnames[:] = [dn for dn in dirnames if dn not in SKIP_DIRS]

        # Gestione submoduli
        if not include_submodules:
            new_dirnames = []
            for dn in dirnames:
                child = d / dn
                if child in result.submodule_dirs_populated or child in result.submodule_dirs_empty:
                    # Submodulo: salta
                    pass
                else:
                    new_dirnames.append(dn)
            dirnames[:] = new_dirnames
        else:
            # Includi submoduli ma salta i loro .git interni
            dirnames[:] = [dn for dn in dirnames if dn != ".git" or d == root]

        # Controlla se è un venv
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

    # Ordinamento per dimensione decrescente (per il report)
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
        return f"ELIMINO  ({rec.category})"
    if rec.warn_large_unknown:
        return "TENGO    ⚠  tipo sconosciuto"
    if rec.warn_large_kept:
        return "TENGO    ⚠  file grande"
    return "TENGO"


def _build_size_report_lines(result: ScanResult) -> list[str]:
    """Costruisce le righe del size report (senza stamparle)."""
    SEP = "\u2500" * 100
    lines = [
        "",
        SEP,
        "  SCANSIONE DIMENSIONI \u2014 tutti i file ordinati dal pi\u00f9 grande al pi\u00f9 piccolo",
        SEP,
        f"  {'DIMENSIONE':>10}  {'STATO':<35}  PERCORSO",
        SEP,
    ]
    for rec in result.all_records:
        label = _status_label(rec)
        rel = rec.path.relative_to(result.root)
        lines.append(f"  {human_size(rec.size):>10}  {label:<35}  {rel}")
    for d in result.venv_dirs:
        sz = dir_total_size(d)
        rel = d.relative_to(result.root)
        lines.append(f"  {human_size(sz):>10}  {'ELIMINO  (venv)':<35}  {rel}/")
    for d in sorted(result.submodule_dirs_populated):
        sz = dir_total_size(d)
        rel = d.relative_to(result.root)
        lines.append(f"  {human_size(sz):>10}  {'ESCLUSO  (submodulo)':<35}  {rel}/")
    for d in sorted(result.submodule_dirs_empty):
        rel = d.relative_to(result.root)
        lines.append(f"  {'0 B':>10}  {'ESCLUSO  (submodulo vuoto)':<35}  {rel}/")
    lines.append(SEP)
    return lines


def print_size_report(result: ScanResult, verbose: bool):
    """
    Con --verbose stampa la lista completa a schermo.
    Senza flag stampa solo i WARNING (se presenti).
    Il log completo viene sempre scritto su file da save_log().
    """
    if verbose:
        for line in _build_size_report_lines(result):
            print(line)
        print()
    else:
        warn_lines = [l for l in _build_size_report_lines(result) if "\u26a0" in l]
        if warn_lines:
            SEP = "\u2500" * 100
            print(f"\n{SEP}")
            print("  DIMENSIONI \u2014 solo file con warning  (usa --verbose per lista completa)")
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
    print(f"  RIEPILOGO — {result.root}")
    print(f"{SEP}")
    print(f"  Modalità:             {mode}")
    print(f"  Categorie attive:     {', '.join(sorted(active_categories))}")
    print()
    print(f"  File da eliminare:    {len(to_delete):>6}  ({human_size(total_delete)})")
    if result.venv_dirs:
        print(f"  Venv da eliminare:    {len(result.venv_dirs):>6}  ({human_size(total_venv)})")
    print(f"  File da tenere:       {len(to_keep):>6}  ({human_size(total_keep)})")
    if result.submodule_dirs_populated or result.submodule_dirs_empty:
        tot_sub = len(result.submodule_dirs_populated) + len(result.submodule_dirs_empty)
        print(f"  Submoduli esclusi:    {tot_sub:>6}")
    if warnings:
        n_unk = sum(1 for r in warnings if r.warn_large_unknown)
        n_kept = sum(1 for r in warnings if r.warn_large_kept)
        print()
        print(f"  ⚠  WARNING dimensioni:")
        if n_unk:
            print(f"      {n_unk} file con tipo non riconosciuto e dimensione elevata")
        if n_kept:
            print(f"      {n_kept} file tenuti con dimensione elevata (testo/codice grande)")
    print(f"{SEP}\n")

    # Per estensione
    by_ext: dict[str, list] = defaultdict(list)
    for r in to_delete:
        by_ext[r.path.suffix.lower()].append(r)
    if by_ext:
        print("  Eliminati per estensione:")
        for ext in sorted(by_ext, key=lambda e: -sum(r.size for r in by_ext[e])):
            recs = by_ext[ext]
            size = sum(r.size for r in recs)
            print(f"    {ext:8s}  →  {len(recs):5d} file  ({human_size(size)})")
        print()

    # Per categoria
    print("  Eliminati per categoria:")
    for cat_name in sorted(active_categories):
        cat = CATEGORIES.get(cat_name, {})
        if cat_name == "venv":
            if result.venv_dirs:
                print(f"    {cat.get('label', cat_name):40s}  {len(result.venv_dirs):5d} directory")
            continue
        recs = [r for r in to_delete if r.category == cat_name]
        if recs:
            print(f"    {cat.get('label', cat_name):40s}  {len(recs):5d} file")
    print()

    # Warning dettagliato
    if warnings:
        print("  ⚠  File con warning dimensione (da verificare manualmente):")
        for r in sorted(warnings, key=lambda r: -r.size):
            rel = r.path.relative_to(result.root)
            tag = "tipo sconosciuto" if r.warn_large_unknown else "testo/codice grande"
            print(f"    {human_size(r.size):>10}  [{tag}]  {rel}")
        print()


def save_log(result: ScanResult, filepath: str):
    """
    Scrive il log completo su file: size scan + dettaglio per sezione.
    Viene sempre chiamato (percorso default o esplicito via --out-report).
    """
    to_delete = result.to_delete
    to_keep = result.to_keep
    warnings = result.large_warnings

    with open(filepath, "w", encoding="utf-8") as f:
        f.write("# strip_repo.py — log completo\n")
        f.write(f"# Root: {result.root}\n\n")

        # Size scan completo
        for line in _build_size_report_lines(result):
            f.write(line + "\n")
        f.write("\n")

        f.write("# ── FILE DA ELIMINARE ────────────────────────────────\n")
        for r in sorted(to_delete, key=lambda r: r.path):
            rel = r.path.relative_to(result.root)
            f.write(f"{human_size(r.size):>10}  [{r.category}]  {rel}\n")

        if result.venv_dirs:
            f.write("\n# ── VENV DA ELIMINARE ────────────────────────────────\n")
            for d in result.venv_dirs:
                rel = d.relative_to(result.root)
                f.write(f"{human_size(dir_total_size(d)):>10}  [venv]  {rel}/\n")

        f.write("\n# ── FILE TENUTI ──────────────────────────────────────\n")
        for r in sorted(to_keep, key=lambda r: -r.size):
            rel = r.path.relative_to(result.root)
            warn = "  ⚠" if (r.warn_large_kept or r.warn_large_unknown) else ""
            f.write(f"{human_size(r.size):>10}  {rel}{warn}\n")

        if warnings:
            f.write("\n# ── WARNING DIMENSIONI ───────────────────────────────\n")
            for r in sorted(warnings, key=lambda r: -r.size):
                rel = r.path.relative_to(result.root)
                tag = "tipo sconosciuto" if r.warn_large_unknown else "testo grande"
                f.write(f"{human_size(r.size):>10}  [{tag}]  {rel}\n")

        if result.submodule_dirs_populated or result.submodule_dirs_empty:
            f.write("\n# ── SUBMODULI ESCLUSI ────────────────────────────────\n")
            for d in sorted(result.submodule_dirs_populated | result.submodule_dirs_empty):
                rel = d.relative_to(result.root)
                populated = d in result.submodule_dirs_populated
                f.write(f"{'popolato' if populated else 'vuoto':>10}  {rel}/\n")

    print(f"  Log salvato in: {filepath}")

def copy_selective(result: ScanResult, output_dir: Path, dry_run: bool) -> tuple[int, int]:
    """
    Ricrea output_dir copiando solo i file da tenere.
    Restituisce (copiati, errori).
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
            print(f"  ERRORE copia: {rel} — {e}", file=sys.stderr)
            err += 1

    return ok, err


# ─────────────────────────────────────────────────────────────
#  ELIMINAZIONE IN-PLACE
# ─────────────────────────────────────────────────────────────

def delete_files(files: list[FileRecord]) -> tuple[int, int]:
    ok = err = 0
    for rec in files:
        try:
            rec.path.unlink()
            ok += 1
        except OSError as e:
            print(f"  ERRORE: {rec.path} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def delete_venv_dirs(venv_dirs: list[Path]) -> tuple[int, int]:
    ok = err = 0
    for d in venv_dirs:
        try:
            shutil.rmtree(d)
            ok += 1
        except OSError as e:
            print(f"  ERRORE rmtree: {d} — {e}", file=sys.stderr)
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
                    print(f"  ERRORE rmdir: {d} — {e}", file=sys.stderr)
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
        description="Pulisce un repository SoC rimuovendo file sensibili, "
                    "pesanti o inutili prima di condividerlo.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Categorie disponibili: " + ", ".join(all_cat_names),
    )
    parser.add_argument(
        "root", type=Path,
        help="Directory radice del progetto",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Mostra cosa verrebbe fatto senza toccare nulla",
    )
    parser.add_argument(
        "--yes", "-y", action="store_true",
        help="Salta la conferma interattiva",
    )
    parser.add_argument(
        "--in-place", action="store_true",
        help="Modifica la repo originale (pericoloso — richiede conferma extra)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Directory di output per la copia (default: <root>_stripped)",
    )
    parser.add_argument(
        "--include-submodules", action="store_true",
        help="Includi i file dei submoduli Git nella copia",
    )
    parser.add_argument(
        "--only", nargs="+", metavar="CAT", choices=all_cat_names,
        help="Attiva solo le categorie elencate",
    )
    parser.add_argument(
        "--skip", nargs="+", metavar="CAT", choices=all_cat_names,
        help="Disattiva le categorie elencate",
    )
    parser.add_argument(
        "--extra-ext", action="append", default=[],
        help="Estensioni aggiuntive da rimuovere (ripetibile)",
    )
    parser.add_argument(
        "--size-warn-threshold", type=float, default=5.0, metavar="MB",
        help="Soglia in MB per i warning sui file grandi (default: 5)",
    )
    parser.add_argument(
        "--out-report", type=str, default=None,
        help="Percorso del file .log (default: <root>_strip.log accanto alla root)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Stampa a schermo la lista completa file per file (default: solo riepilogo)",
    )
    parser.add_argument(
        "--keep-empty-dirs", action="store_true",
        help="Non rimuovere cartelle vuote (solo --in-place)",
    )

    args = parser.parse_args()

    # Validazione root
    root = args.root.resolve()
    if not root.is_dir():
        print(f"Errore: '{root}' non è una directory valida.", file=sys.stderr)
        sys.exit(1)

    # Categorie attive
    if args.only:
        active = set(args.only)
    else:
        active = set(all_cat_names)
    if args.skip:
        active -= set(args.skip)
    if not active:
        print("Errore: nessuna categoria attiva.", file=sys.stderr)
        sys.exit(1)

    # Estensioni extra
    extra_ext = set()
    for ext in args.extra_ext:
        if not ext.startswith("."):
            ext = "." + ext
        extra_ext.add(ext.lower())

    # Modalità operativa
    in_place = args.in_place
    if in_place:
        mode_label = "IN-PLACE (modifica originale)"
        output_dir = None
    else:
        if args.output_dir:
            output_dir = args.output_dir.resolve()
        else:
            output_dir = root.parent / (root.name + "_stripped")
        mode_label = f"COPIA SICURA → {output_dir}"

    size_warn_bytes = int(args.size_warn_threshold * 1024 * 1024)

    # ── SCANSIONE ──────────────────────────────────────────────
    print(f"\n  Scansione in corso: {root} ...")
    result = scan(root, active, extra_ext, size_warn_bytes, args.include_submodules)

    if not result.all_records and not result.venv_dirs:
        print("\n  Nessun file trovato. Nulla da fare.\n")
        sys.exit(0)

    # ── REPORT DIMENSIONI (sempre, tutti i file) ───────────────
    print_size_report(result, args.verbose)

    # ── RIEPILOGO ──────────────────────────────────────────────
    print_summary(result, active, mode_label)

    # ── LOG SU FILE (sempre) ────────────────────────
    log_path = args.out_report if args.out_report else str(root.parent / (root.name + '_strip.log'))
    save_log(result, log_path)

    # ── DRY-RUN ────────────────────────────────────────────────
    if args.dry_run:
        if in_place:
            print("  [DRY-RUN] Nessun file eliminato.")
            empty_dirs = find_dirs_that_would_be_empty(result)
            if not args.keep_empty_dirs and empty_dirs:
                print(f"\n  Cartelle che verrebbero rimosse (rimaste vuote): {len(empty_dirs)}")
                for d in empty_dirs:
                    print(f"    {d.relative_to(root)}/")
        else:
            print(f"  [DRY-RUN] Verrebbero copiati {len(result.to_keep)} file in:")
            print(f"    {output_dir}")
        print()
        sys.exit(0)

    # ── CONFERMA ───────────────────────────────────────────────
    if not args.yes:
        if in_place:
            # Doppia conferma per l'operazione distruttiva
            print("  ⚠  ATTENZIONE: modalità IN-PLACE. La repo originale verrà modificata.")
            risposta = input(
                f"  Confermi l'eliminazione di {len(result.to_delete)} file"
                + (f" e {len(result.venv_dirs)} venv" if result.venv_dirs else "")
                + " DALLA REPO ORIGINALE? [scrivi 'SI' in maiuscolo per confermare] "
            ).strip()
            if risposta != "SI":
                print("  Operazione annullata.\n")
                sys.exit(0)
        else:
            if output_dir.exists():
                print(f"  ⚠  La directory di output esiste già: {output_dir}")
                risposta = input(
                    f"  Sovrascrivere copiando {len(result.to_keep)} file da tenere? [s/N] "
                ).strip().lower()
            else:
                risposta = input(
                    f"  Copiare {len(result.to_keep)} file in '{output_dir}'? [s/N] "
                ).strip().lower()
            if risposta not in ("s", "si", "sì", "y", "yes"):
                print("  Operazione annullata.\n")
                sys.exit(0)

    # ── ESECUZIONE ─────────────────────────────────────────────
    if in_place:
        f_ok, f_err = delete_files(result.to_delete)
        print(f"\n  File eliminati: {f_ok}, errori: {f_err}")

        if result.venv_dirs:
            v_ok, v_err = delete_venv_dirs(result.venv_dirs)
            print(f"  Venv rimossi: {v_ok}, errori: {v_err}")

        if not args.keep_empty_dirs:
            pruned = prune_empty_dirs(root)
            if pruned:
                print(f"  Cartelle vuote rimosse: {len(pruned)}")
                for d in pruned[:15]:
                    print(f"    {d.relative_to(root)}/")
                if len(pruned) > 15:
                    print(f"    ... e altre {len(pruned) - 15}")
            else:
                print("  Nessuna cartella rimasta vuota.")
    else:
        print(f"\n  Copia selettiva in corso → {output_dir} ...")
        c_ok, c_err = copy_selective(result, output_dir, dry_run=False)
        print(f"  File copiati: {c_ok}, errori: {c_err}")
        if result.large_warnings:
            print(f"\n  ⚠  {len(result.large_warnings)} file con warning dimensione nella copia.")
            print(f"     Vedi il log per i dettagli: {log_path}")

    print()


if __name__ == "__main__":
    main()

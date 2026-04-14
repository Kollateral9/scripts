#!/usr/bin/env python3
"""
strip_repo.py
~~~~~~~~~~~~~
Pulisce un repository SoC rimuovendo file sensibili / pesanti / inutili
prima di condividerlo, preservando tutto ciò che serve per analizzare
il build system (CMake, Bazel, script, sorgenti C, header, ecc.).

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
    python3 strip_repo.py /percorso/alla/repo                     # tutto
    python3 strip_repo.py /percorso/alla/repo --only hdl netlist  # solo alcune
    python3 strip_repo.py /percorso/alla/repo --skip docs         # tutte tranne docs
    python3 strip_repo.py /percorso/alla/repo --dry-run           # anteprima

Opzioni:
    --dry-run         Mostra cosa verrebbe eliminato senza toccare nulla
    --yes / -y        Salta la conferma interattiva
    --only CAT [...]  Attiva solo le categorie elencate
    --skip CAT [...]  Disattiva le categorie elencate
    --extra-ext EXT   Aggiunge estensioni extra da rimuovere (ripetibile)
    --out-report F    Salva il report in un file di testo
    --keep-empty-dirs Non rimuovere le cartelle vuote dopo l'eliminazione
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path
from collections import defaultdict

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
        # .tcl è ambiguo — potrebbe essere uno script di build legittimo,
        # quindi NON lo includiamo per estensione. Lo cerchiamo per pattern.
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
            ".edf", ".edif", ".ngc", ".ncd",     # netlist
            ".dcp", ".xpr",                        # Vivado project / checkpoint
            ".bit", ".bin", ".mcs", ".mmi",        # bitstream / memory map
            ".rpt",                                # report di sintesi
        },
    },
    "venv": {
        "label": "Ambienti virtuali Python",
        # Gestito a livello di directory, non di estensione
        "extensions": set(),
        "directory_markers": True,
    },
    "build_junk": {
        "label": "Artefatti di compilazione / simulazione",
        "extensions": {
            ".o", ".obj", ".a", ".lib", ".so", ".dll", ".dylib",
            ".elf", ".hex", ".srec", ".map",
            ".vcd", ".fsdb", ".wlf", ".ghw",      # dump di simulazione
            ".log",                                 # log di sintesi / sim
        },
    },
}

# Nomi di directory che identificano un venv Python
VENV_MARKERS = {"pyvenv.cfg"}
VENV_DIR_NAMES = {"venv", ".venv", "env", ".env", "virtualenv", ".virtualenv"}

# Directory da ignorare sempre durante la scansione
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


# ─────────────────────────────────────────────────────────────
#  SCANSIONE
# ─────────────────────────────────────────────────────────────

def is_venv_dir(d: Path) -> bool:
    """Controlla se una directory è un ambiente virtuale Python."""
    # Metodo 1: contiene pyvenv.cfg
    if (d / "pyvenv.cfg").exists():
        return True
    # Metodo 2: nome tipico + contiene bin/activate o Scripts/activate
    if d.name.lower() in VENV_DIR_NAMES:
        if (d / "bin" / "activate").exists() or (d / "Scripts" / "activate").exists():
            return True
    return False


def find_files_to_delete(
    root: Path,
    active_categories: set[str],
    extra_extensions: set[str],
) -> tuple[list[Path], list[Path]]:
    """Scansiona il progetto.

    Restituisce (files_to_delete, venv_dirs_to_delete).
    """
    # Raccogli tutte le estensioni attive
    all_extensions = extra_extensions.copy()
    filename_patterns = []
    check_venv = "venv" in active_categories

    for cat_name in active_categories:
        cat = CATEGORIES.get(cat_name)
        if cat:
            all_extensions |= cat.get("extensions", set())
            filename_patterns.extend(cat.get("filename_patterns", []))

    files = []
    venv_dirs = []

    for dirpath, dirnames, filenames in os.walk(root):
        d = Path(dirpath)

        # Salta directory protette
        dirnames[:] = [
            dn for dn in dirnames
            if dn not in SKIP_DIRS
        ]

        # Controlla se è un venv
        if check_venv and d != root and is_venv_dir(d):
            venv_dirs.append(d)
            dirnames.clear()  # non scendere dentro
            continue

        for fname in filenames:
            fpath = d / fname
            suffix = Path(fname).suffix.lower()

            # Match per estensione
            if suffix in all_extensions:
                files.append(fpath)
                continue

            # Match per pattern sul nome file
            if any(p.match(fname) for p in filename_patterns):
                files.append(fpath)

    files.sort()
    venv_dirs.sort()
    return files, venv_dirs


# ─────────────────────────────────────────────────────────────
#  OUTPUT
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


def print_summary(
    files: list[Path],
    venv_dirs: list[Path],
    root: Path,
    active_categories: set[str],
):
    total_size = 0
    by_ext = defaultdict(list)
    for f in files:
        by_ext[f.suffix.lower()].append(f)
        try:
            total_size += f.stat().st_size
        except OSError:
            pass

    venv_size = sum(dir_total_size(d) for d in venv_dirs)

    print(f"\n{'='*64}")
    print(f"  RIEPILOGO SCAN — {root}")
    print(f"{'='*64}")
    print(f"  Categorie attive:   {', '.join(sorted(active_categories))}")
    print(f"  File da eliminare:  {len(files)}")
    if venv_dirs:
        print(f"  Venv da eliminare:  {len(venv_dirs)}")
    print(f"  Dimensione totale:  {human_size(total_size + venv_size)}")
    print(f"{'='*64}\n")

    # Per estensione
    if by_ext:
        print("  Per estensione:")
        for ext in sorted(by_ext):
            count = len(by_ext[ext])
            size = sum(f.stat().st_size for f in by_ext[ext] if f.exists())
            print(f"    {ext:8s}  →  {count:5d} file  ({human_size(size)})")
        print()

    # Per categoria
    print("  Per categoria:")
    for cat_name in sorted(active_categories):
        cat = CATEGORIES.get(cat_name, {})
        exts = cat.get("extensions", set())
        patterns = cat.get("filename_patterns", [])
        if cat_name == "venv":
            print(f"    {cat.get('label', cat_name):40s}  {len(venv_dirs):5d} directory")
            continue
        count = 0
        for f in files:
            suffix = f.suffix.lower()
            if suffix in exts:
                count += 1
            elif any(p.match(f.name) for p in patterns):
                count += 1
        if count > 0:
            print(f"    {cat.get('label', cat_name):40s}  {count:5d} file")
    print()

    # Top directory
    by_dir = defaultdict(int)
    for f in files:
        rel = f.relative_to(root)
        top = rel.parts[0] if len(rel.parts) > 1 else "."
        by_dir[top] += 1

    if by_dir:
        print("  Directory principali:")
        for d, count in sorted(by_dir.items(), key=lambda x: -x[1])[:10]:
            print(f"    {d:35s}  {count:5d} file")
        print()


def save_report(
    files: list[Path],
    venv_dirs: list[Path],
    root: Path,
    filepath: str,
):
    with open(filepath, "w") as f:
        if files:
            f.write("# File da eliminare\n")
            for p in files:
                f.write(str(p.relative_to(root)) + "\n")
        if venv_dirs:
            f.write("\n# Directory venv da eliminare\n")
            for d in venv_dirs:
                f.write(str(d.relative_to(root)) + "/\n")
    print(f"  Report salvato in: {filepath}")


# ─────────────────────────────────────────────────────────────
#  ELIMINAZIONE
# ─────────────────────────────────────────────────────────────

def delete_files(files: list[Path]) -> tuple[int, int]:
    ok, err = 0, 0
    for f in files:
        try:
            f.unlink()
            ok += 1
        except OSError as e:
            print(f"  ERRORE: {f} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def delete_venv_dirs(venv_dirs: list[Path]) -> tuple[int, int]:
    ok, err = 0, 0
    for d in venv_dirs:
        try:
            shutil.rmtree(d)
            ok += 1
        except OSError as e:
            print(f"  ERRORE rmtree: {d} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def prune_empty_dirs(root: Path, dry_run: bool = False) -> list[Path]:
    """Rimuove ricorsivamente le cartelle vuote (bottom-up)."""
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


def find_dirs_that_would_be_empty(
    files_to_delete: list[Path],
    venv_dirs: list[Path],
    root: Path,
) -> list[Path]:
    """Simula quali cartelle resterebbero vuote (per dry-run)."""
    deleted_set = set(files_to_delete)
    would_remove: set[Path] = set(venv_dirs)

    all_dirs = set()
    for f in files_to_delete:
        p = f.parent
        while p != root and p != p.parent:
            all_dirs.add(p)
            p = p.parent
    for v in venv_dirs:
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
        all_gone = all(
            (c in deleted_set) or (c in would_remove)
            for c in children
        )
        if all_gone and children:
            would_remove.add(d)

    # Non ri-elencare le venv, sono già gestite separatamente
    return sorted(would_remove - set(venv_dirs))


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
        help="Mostra cosa verrebbe eliminato senza cancellare nulla",
    )
    parser.add_argument(
        "--yes", "-y", action="store_true",
        help="Salta la conferma interattiva",
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
        "--out-report", type=str, default=None,
        help="Salva il report in un file di testo",
    )
    parser.add_argument(
        "--keep-empty-dirs", action="store_true",
        help="Non rimuovere le cartelle rimaste vuote dopo l'eliminazione",
    )

    args = parser.parse_args()

    if not args.root.is_dir():
        print(f"Errore: '{args.root}' non è una directory valida.", file=sys.stderr)
        sys.exit(1)

    # Determina categorie attive
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

    # Scan
    print(f"\n  Scansione in corso: {args.root.resolve()} ...")
    files, venv_dirs = find_files_to_delete(args.root, active, extra_ext)

    if not files and not venv_dirs:
        print("\n  Nessun file da eliminare trovato. Nulla da fare.\n")
        sys.exit(0)

    print_summary(files, venv_dirs, args.root, active)

    # Report
    if args.out_report:
        save_report(files, venv_dirs, args.root, args.out_report)

    # Lista file
    if files:
        print("  File che verranno eliminati:")
        show_max = 30
        for f in files[:show_max]:
            print(f"    {f.relative_to(args.root)}")
        if len(files) > show_max:
            print(f"    ... e altri {len(files) - show_max} file")
            print(f"    (usa --out-report per la lista completa)")
        print()

    # Lista venv
    if venv_dirs:
        print("  Directory venv che verranno eliminate:")
        for d in venv_dirs:
            size = dir_total_size(d)
            print(f"    {d.relative_to(args.root)}/  ({human_size(size)})")
        print()

    # Dry-run
    if args.dry_run:
        print("  [DRY-RUN] Nessun file eliminato.")
        if not args.keep_empty_dirs:
            empty_dirs = find_dirs_that_would_be_empty(files, venv_dirs, args.root)
            if empty_dirs:
                print(f"\n  Cartelle che verrebbero rimosse (rimaste vuote): {len(empty_dirs)}")
                for d in empty_dirs[:20]:
                    print(f"    {d.relative_to(args.root)}/")
                if len(empty_dirs) > 20:
                    print(f"    ... e altre {len(empty_dirs) - 20}")
        print()
        sys.exit(0)

    # Conferma
    total_items = len(files) + len(venv_dirs)
    if not args.yes:
        risposta = input(
            f"  Confermi l'eliminazione di {len(files)} file"
            + (f" e {len(venv_dirs)} venv" if venv_dirs else "")
            + "? [s/N] "
        ).strip().lower()
        if risposta not in ("s", "si", "sì", "y", "yes"):
            print("  Operazione annullata.\n")
            sys.exit(0)

    # Eliminazione
    f_ok, f_err = delete_files(files)
    print(f"\n  File: {f_ok} eliminati, {f_err} errori.")

    if venv_dirs:
        v_ok, v_err = delete_venv_dirs(venv_dirs)
        print(f"  Venv: {v_ok} rimossi, {v_err} errori.")

    # Pulizia cartelle vuote
    if not args.keep_empty_dirs:
        pruned = prune_empty_dirs(args.root)
        if pruned:
            print(f"  Cartelle vuote rimosse: {len(pruned)}")
            for d in pruned[:15]:
                print(f"    {d.relative_to(args.root)}/")
            if len(pruned) > 15:
                print(f"    ... e altre {len(pruned) - 15}")
        else:
            print("  Nessuna cartella rimasta vuota.")
    print()


if __name__ == "__main__":
    main()

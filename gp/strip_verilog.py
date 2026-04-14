#!/usr/bin/env python3
"""
strip_hdl.py
~~~~~~~~~~~~
Cerca e rimuove file Verilog / SystemVerilog / VHDL da un progetto,
preservando tutto il resto (BUILD, CMake, script, C, Python, ecc.).
Dopo l'eliminazione, rimuove ricorsivamente le cartelle rimaste vuote.

Uso:
    python3 strip_hdl.py /percorso/alla/repo

Opzioni:
    --dry-run         Mostra solo cosa verrebbe eliminato, senza toccare nulla
    --yes             Salta la conferma interattiva
    --extra-ext EXT   Aggiunge estensioni extra da rimuovere (ripetibile)
    --out-report F    Salva il report in un file di testo
    --keep-empty-dirs Non rimuovere le cartelle vuote dopo l'eliminazione
"""

import argparse
import os
import sys
from pathlib import Path
from collections import defaultdict

# Estensioni Verilog / SystemVerilog / VHDL (case-insensitive)
DEFAULT_EXTENSIONS = {
    # Verilog / SystemVerilog
    ".v",
    ".sv",
    ".vh",
    ".svh",
    ".svi",        # SystemVerilog include (usato in alcuni flussi)
    ".vlib",       # library file Verilog
    # VHDL
    ".vhd",
    ".vhdl",
}

# Directory da ignorare sempre (evita di entrare in .git, build artifacts, ecc.)
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
    """Scansiona ricorsivamente e restituisce i file con le estensioni date."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Elimina in-place le directory da non visitare
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
    """Stampa un riepilogo raggruppato per estensione e directory."""
    by_ext = defaultdict(list)
    total_size = 0

    for f in files:
        by_ext[f.suffix.lower()].append(f)
        try:
            total_size += f.stat().st_size
        except OSError:
            pass

    print(f"\n{'='*60}")
    print(f"  RIEPILOGO SCAN — {root}")
    print(f"{'='*60}")
    print(f"  File trovati:  {len(files)}")
    print(f"  Dimensione:    {human_size(total_size)}")
    print(f"  Estensioni:    {', '.join(sorted(extensions))}")
    print(f"{'='*60}\n")

    # Breakdown per estensione
    print("  Per estensione:")
    for ext in sorted(by_ext):
        count = len(by_ext[ext])
        size = sum(f.stat().st_size for f in by_ext[ext] if f.exists())
        print(f"    {ext:6s}  →  {count:5d} file  ({human_size(size)})")

    # Top 10 directory con più file
    by_dir = defaultdict(int)
    for f in files:
        rel = f.relative_to(root)
        top = rel.parts[0] if len(rel.parts) > 1 else "."
        by_dir[top] += 1

    print("\n  Directory principali:")
    for d, count in sorted(by_dir.items(), key=lambda x: -x[1])[:10]:
        print(f"    {d:30s}  {count:5d} file")
    print()


def save_report(files: list[Path], root: Path, filepath: str):
    """Salva la lista completa dei file in un file di testo."""
    with open(filepath, "w") as f:
        for p in files:
            f.write(str(p.relative_to(root)) + "\n")
    print(f"  Report salvato in: {filepath}")


def delete_files(files: list[Path]) -> tuple[int, int]:
    """Elimina i file. Restituisce (successi, errori)."""
    ok, err = 0, 0
    for f in files:
        try:
            f.unlink()
            ok += 1
        except OSError as e:
            print(f"  ERRORE: {f} — {e}", file=sys.stderr)
            err += 1
    return ok, err


def prune_empty_dirs(root: Path, dry_run: bool = False) -> list[Path]:
    """Rimuove ricorsivamente le cartelle vuote dal basso verso l'alto.

    Funziona bottom-up: se una sottocartella diventa vuota dopo la
    rimozione dei file HDL, viene eliminata. Se questo rende vuota
    anche la cartella genitore, viene eliminata a sua volta, e così via
    fino alla root (che non viene mai rimossa).

    Restituisce la lista delle cartelle rimosse (o che verrebbero
    rimosse in dry-run).
    """
    removed = []
    # os.walk bottom-up: visita prima le foglie
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        d = Path(dirpath)
        # Non rimuovere mai la root stessa
        if d == root:
            continue
        # Salta le directory protette
        if d.name in SKIP_DIRS:
            continue
        # Controlla se la directory è effettivamente vuota ora
        # (i figli potrebbero essere stati rimossi nelle iterazioni precedenti)
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
    files_to_delete: list[Path], root: Path
) -> list[Path]:
    """Simula quali cartelle resterebbero vuote dopo la rimozione dei file.

    Usata in modalità dry-run per dare un'anteprima senza toccare nulla.
    """
    # Raccogli tutte le directory del progetto e il loro contenuto
    deleted_set = set(files_to_delete)
    would_remove: set[Path] = set()

    # Bottom-up: parti dalle foglie
    all_dirs = set()
    for f in files_to_delete:
        p = f.parent
        while p != root and p != p.parent:
            all_dirs.add(p)
            p = p.parent

    # Ordina per profondità decrescente (foglie prima)
    for d in sorted(all_dirs, key=lambda x: len(x.parts), reverse=True):
        if d.name in SKIP_DIRS:
            continue
        try:
            children = list(d.iterdir())
        except OSError:
            continue
        # Una directory è "vuota" se ogni suo figlio è un file da eliminare
        # oppure una sottocartella che verrebbe rimossa
        all_gone = all(
            (c in deleted_set) or (c in would_remove)
            for c in children
        )
        if all_gone and children:  # non segnalare dir già vuote
            would_remove.add(d)

    return sorted(would_remove)


def main():
    parser = argparse.ArgumentParser(
        description="Rimuove file Verilog/SystemVerilog/VHDL da un progetto "
                    "e pulisce le cartelle rimaste vuote"
    )
    parser.add_argument(
        "root",
        type=Path,
        help="Directory radice del progetto"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Mostra cosa verrebbe eliminato senza cancellare nulla"
    )
    parser.add_argument(
        "--yes", "-y",
        action="store_true",
        help="Salta la conferma interattiva"
    )
    parser.add_argument(
        "--extra-ext",
        action="append",
        default=[],
        help="Estensioni aggiuntive da rimuovere (es: --extra-ext .tcl)"
    )
    parser.add_argument(
        "--out-report",
        type=str,
        default=None,
        help="Salva la lista dei file trovati in un file di testo"
    )
    parser.add_argument(
        "--keep-empty-dirs",
        action="store_true",
        help="Non rimuovere le cartelle rimaste vuote dopo l'eliminazione"
    )

    args = parser.parse_args()

    if not args.root.is_dir():
        print(f"Errore: '{args.root}' non è una directory valida.", file=sys.stderr)
        sys.exit(1)

    # Componi set estensioni
    extensions = DEFAULT_EXTENSIONS.copy()
    for ext in args.extra_ext:
        if not ext.startswith("."):
            ext = "." + ext
        extensions.add(ext.lower())

    # Scan
    print(f"\n  Scansione in corso: {args.root.resolve()} ...")
    files = find_verilog_files(args.root, extensions)

    if not files:
        print("\n  Nessun file HDL (Verilog/SV/VHDL) trovato. Nulla da fare.\n")
        sys.exit(0)

    print_summary(files, args.root, extensions)

    # Report opzionale
    if args.out_report:
        save_report(files, args.root, args.out_report)

    # Lista completa (mostra i primi 30 + ellipsis)
    print("  File che verranno eliminati:")
    show_max = 30
    for f in files[:show_max]:
        print(f"    {f.relative_to(args.root)}")
    if len(files) > show_max:
        print(f"    ... e altri {len(files) - show_max} file")
        print(f"    (usa --out-report per la lista completa)")
    print()

    if args.dry_run:
        print("  [DRY-RUN] Nessun file eliminato.")
        if not args.keep_empty_dirs:
            # Simula la pulizia: conta le cartelle che conterrebbero solo file HDL
            empty_dirs = find_dirs_that_would_be_empty(files, args.root)
            if empty_dirs:
                print(f"\n  Cartelle che verrebbero rimosse (rimaste vuote): {len(empty_dirs)}")
                for d in empty_dirs[:20]:
                    print(f"    {d.relative_to(args.root)}/")
                if len(empty_dirs) > 20:
                    print(f"    ... e altre {len(empty_dirs) - 20}")
        print()
        sys.exit(0)

    # Conferma
    if not args.yes:
        risposta = input(
            f"  Confermi l'eliminazione di {len(files)} file? [s/N] "
        ).strip().lower()
        if risposta not in ("s", "si", "sì", "y", "yes"):
            print("  Operazione annullata.\n")
            sys.exit(0)

    # Eliminazione file
    ok, err = delete_files(files)
    print(f"\n  File: {ok} eliminati, {err} errori.")

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

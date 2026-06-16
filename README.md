# scripts

A small collection of personal utility scripts: dev-machine setup for Linux and
Windows, SSH/Git identity bootstrap, and a few Python tools for cleaning up and
bundling repositories.

All setup scripts are **idempotent** — re-running them is safe and only applies
what is missing.

## Layout

| Path | Platform | What it does |
|------|----------|--------------|
| [Linux/setup_pc.sh](Linux/setup_pc.sh) | Ubuntu/Debian + derivatives | Installs a full dev toolchain (CLI tools, Chrome, VSCode, gh, Docker, pyenv, nvm, DB tools) and configures `.bashrc`. |
| [Linux/setup_ssh.sh](Linux/setup_ssh.sh) | Linux/macOS | Generates an SSH key per Git host, registers it in `~/.ssh/config`, tests the connection, and sets the Git identity (global or per-folder). |
| [Linux/forceGitName.sh](Linux/forceGitName.sh) | Git Bash / Linux | Rewrites author/committer name & email across the **entire** history of a repo (edit the values inside before use). |
| [Windows/setup_pc.ps1](Windows/setup_pc.ps1) | Windows | winget-based dev setup: CLI tools, Chrome, VSCode, gh, DB tools, WSL2 + Docker Desktop, Node via nvm-windows, Python via the Python Install Manager, and a smart PowerShell profile (5.1 + PS7) with PSReadLine predictions + posh-git. Prints an honest end-of-run summary (installed / failed / skipped). |
| [Windows/setup_ssh.ps1](Windows/setup_ssh.ps1) | Windows | PowerShell port of `setup_ssh.sh`. |
| [Windows/WTContextMenu.ps1](Windows/WTContextMenu.ps1) | Windows | Adds an "Open in Windows Terminal Here" right-click entry (HKCU, no admin). |
| [gp/oneFiler.py](gp/oneFiler.py) | any | Concatenates all text files of a project into a single `oneFile_project.txt` (e.g. to feed an LLM). |
| [gp/strip_repo.py](gp/strip_repo.py) | any | Cleans a repo of sensitive/heavy/generated files (including HDL: Verilog/SV/VHDL via `--only hdl`). Defaults to a **safe copy** next to the original. |
| [gp/update_changelog.py](gp/update_changelog.py) | any | Generates/updates `CHANGELOG.md` from git tags in the "Keep a Changelog" format. |

## Usage

### Linux dev setup

```bash
sudo bash Linux/setup_pc.sh            # install / update everything
bash      Linux/setup_pc.sh --check    # read-only status report (no sudo)
sudo bash Linux/setup_pc.sh --force-repos
```

Supports Ubuntu, Debian and their derivatives (Linux Mint, Pop!_OS, elementary,
Zorin, …) via `ID_LIKE`. Runs unattended (`DEBIAN_FRONTEND=noninteractive`).

### SSH / Git identity

```bash
bash Linux/setup_ssh.sh                 # interactive: asks for the host
bash Linux/setup_ssh.sh --host github.com
bash Linux/setup_ssh.sh --config-only   # only set Git identity, no SSH
bash Linux/setup_ssh.sh --remove-all    # delete all SSH keys (asks confirmation)
```

### Windows

Run from an **elevated** PowerShell:

```powershell
.\Windows\setup_pc.ps1                 # install / update
.\Windows\setup_pc.ps1 -Check          # read-only status report
.\Windows\setup_pc.ps1 -SkipDocker -SkipWSL
.\Windows\setup_ssh.ps1 -Host github.com
.\Windows\WTContextMenu.ps1            # add right-click entry (-Uninstall to remove)
```

### Managing language runtimes (Node & Python)

Languages are handled by version managers, never as a single global install, so
you can keep multiple versions side by side:

- **Node** — `nvm` on Linux, `nvm-windows` on Windows
- **Python** — `pyenv` on Linux, the Python Install Manager (`py`) on Windows (the
  official Windows tool)

```bash
# Node (nvm / nvm-windows)
nvm install --lts    # latest LTS    (Windows: nvm install lts)
nvm use 20           # switch the active version
nvm ls               # list installed  (Windows: nvm list)
```

```powershell
# Python on Windows (Python Install Manager)
py install 3.13      # install a version  (setup pins 3.13 by default)
py list              # list installed versions
py -3.13             # run a specific version
```

On **Windows**, `setup_pc.ps1`:

- installs **Node** via nvm-windows and, on first install, the latest LTS. It
  first removes a pre-existing standalone Node (e.g. from the official `.msi`)
  because a global Node and nvm fight over `C:\Program Files\nodejs` and the PATH.
  `setup_pc.ps1 -Check` flags such a standalone Node up front.
- installs **Python** via the Python Install Manager and adds the pinned version
  (`$PythonVersion`, default `3.13`) only when no runtime exists yet. Change that
  one variable near the top of the script to pick a different version.

### Windows setup notes

- **Run elevated.** Machine-scope installs and the WSL symlink need Administrator.
- **WSL before Docker.** WSL2 is installed first (Docker Desktop depends on it); a
  transient distro download failure falls back to installing just the WSL platform.
- **Honest summary.** The run ends with a per-item OK / failed / skipped report
  built from real outcomes — re-run to retry failures (winget can be flaky mid-run).
- **`--exact` is case-sensitive** in winget, and a forced `--scope machine` is
  retried without an explicit scope, so package ids must match winget exactly.
- **PowerShell profile** is written for both Windows PowerShell 5.1 and
  PowerShell 7; prediction options are version-guarded (plugin predictions need
  7.2+) and wrapped so they never error in a redirected/non-interactive console.

### Python tools

```bash
python3 gp/oneFiler.py [PATH]                  # default: current directory
python3 gp/strip_repo.py /path/to/repo --dry-run
python3 gp/strip_repo.py /path/to/repo         # safe copy -> <repo>_stripped/
python3 gp/strip_repo.py /path/to/repo --in-place   # destructive (double confirm)
python3 gp/update_changelog.py                 # update CHANGELOG.md
python3 gp/update_changelog.py --check         # exit 1 if tags are undocumented
```

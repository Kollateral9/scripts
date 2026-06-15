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
| [Windows/setup_pc.ps1](Windows/setup_pc.ps1) | Windows | winget-based equivalent of `setup_pc.sh` (+ WSL2/Docker Desktop, smart PowerShell profile with PSReadLine predictions + posh-git). |
| [Windows/setup_ssh.ps1](Windows/setup_ssh.ps1) | Windows | PowerShell port of `setup_ssh.sh`. |
| [Windows/WTContextMenu.ps1](Windows/WTContextMenu.ps1) | Windows | Adds an "Open in Windows Terminal Here" right-click entry (HKCU, no admin). |
| [gp/oneFiler.py](gp/oneFiler.py) | any | Concatenates all text files of a project into a single `oneFile_project.txt` (e.g. to feed an LLM). |
| [gp/strip_repo.py](gp/strip_repo.py) | any | Cleans a repo of sensitive/heavy/generated files. Defaults to a **safe copy** next to the original. |
| [gp/strip_verilog.py](gp/strip_verilog.py) | any | Removes HDL files (Verilog/SV/VHDL) and prunes empty dirs. (Subset of `strip_repo.py`'s `hdl` category.) |
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

### Python tools

```bash
python3 gp/oneFiler.py [PATH]                  # default: current directory
python3 gp/strip_repo.py /path/to/repo --dry-run
python3 gp/strip_repo.py /path/to/repo         # safe copy -> <repo>_stripped/
python3 gp/strip_repo.py /path/to/repo --in-place   # destructive (double confirm)
python3 gp/update_changelog.py                 # update CHANGELOG.md
python3 gp/update_changelog.py --check         # exit 1 if tags are undocumented
```

> ⚠️ `strip_verilog.py` deletes **in place** and has no safe-copy mode — prefer
> `strip_repo.py --only hdl` for the same result without touching the original.

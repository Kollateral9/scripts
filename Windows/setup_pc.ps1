# =============================================================
#  setup_pc.ps1 -- Dev machine setup for Windows (winget-based)
#
#  Usage:
#    Run as Administrator.
#
#    .\setup_pc.ps1                  # Install / update everything
#    .\setup_pc.ps1 -Check           # Read-only status report
#    .\setup_pc.ps1 -SkipDocker      # Install everything except Docker Desktop
#    .\setup_pc.ps1 -SkipWSL         # Install everything except WSL2 + Ubuntu
# =============================================================

param(
    [switch]$Check,
    [switch]$SkipDocker,
    [switch]$SkipWSL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ───────────────────────────────────────────────────
function log     { param($m) Write-Host " [OK] $m" -ForegroundColor Green }
function warn    { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function info    { param($m) Write-Host "  [i] $m" -ForegroundColor Cyan }
function err     { param($m) Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }
function rule    { Write-Host ("=" * 65) -ForegroundColor DarkGray }
function section { param($m) Write-Host ""; Write-Host "> $m" -ForegroundColor Cyan -BackgroundColor Black }
function blank   { Write-Host "" }

# ── Admin check ───────────────────────────────────────────────
function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── winget presence check ─────────────────────────────────────
function Test-WingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# ── Check if a winget package is already installed ────────────
# winget list --id <Id> returns exit 0 even if nothing matches,
# so we grep the output for the id itself.
function Test-WingetInstalled {
    param([string]$PackageId)
    $output = winget list --id $PackageId --exact --accept-source-agreements 2>$null | Out-String
    return ($output -match [regex]::Escape($PackageId))
}

# ── Install a winget package idempotently ─────────────────────
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Label = $Id,
        [string]$Scope = "machine"
    )
    if (Test-WingetInstalled -PackageId $Id) {
        warn "${Label}: already installed, skipped."
        return $false
    }
    info "${Label}: installing (id=$Id, scope=$Scope)..."
    # --silent: no UI   --accept-*: skip interactive prompts
    winget install --id $Id --exact --scope $Scope `
        --silent --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        log  "${Label}: installed."
        return $true
    } else {
        warn "${Label}: winget exit code $LASTEXITCODE (may have failed)."
        return $false
    }
}

# ── PowerShell profile helpers (equivalent of .bashrc handling) ──
function Get-ProfilePath {
    # CurrentUserAllHosts is the closest thing to .bashrc: loads for
    # all PowerShell hosts (console, ISE, VSCode integrated terminal).
    return $PROFILE.CurrentUserAllHosts
}

function Ensure-ProfileFile {
    $p = Get-ProfilePath
    if (-not (Test-Path $p)) {
        New-Item -ItemType File -Path $p -Force | Out-Null
        log "Created PowerShell profile: $p"
    }
    return $p
}

# Append a block to the profile only if the marker pattern isn't already present.
# Mirrors the bash `grep -q ... || append` pattern.
function Add-ProfileBlock {
    param(
        [Parameter(Mandatory)][string]$Marker,   # regex / literal string to search for
        [Parameter(Mandatory)][string]$Block,    # content to append (leading newline added)
        [string]$Label = "profile block"
    )
    $profilePath = Ensure-ProfileFile
    $current = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $current) { $current = "" }

    if ($current -match [regex]::Escape($Marker)) {
        warn "${Label}: already in profile, skipped."
        return
    }

    # Ensure the file ends with a newline before appending (mirrors ensure_bashrc_newline)
    if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) {
        Add-Content -Path $profilePath -Value ""
    }

    Add-Content -Path $profilePath -Value $Block
    log "${Label}: added to profile."
}

# ── Refresh PATH in current session after winget installs ─────
# winget modifies the persistent PATH but doesn't touch the current
# PowerShell process's $env:Path, so newly-installed tools aren't
# visible until the next shell. This merges Machine+User PATH into
# the current session.
function Update-EnvPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

# =============================================================
#  CHECK MODE
# =============================================================
if ($Check) {
    blank
    rule
    Write-Host "  setup_pc.ps1 -Check   (read-only status report)" -ForegroundColor Cyan
    rule

    function Check-Cmd {
        param([string]$Label, [string]$Cmd)
        $c = Get-Command $Cmd -ErrorAction SilentlyContinue
        if ($c) {
            $ver = $null
            try { $ver = (& $Cmd --version 2>$null | Select-Object -First 1) } catch {}
            if (-not $ver) { $ver = "installed" }
            log "${Label}: $ver"
        } else {
            warn "${Label}: not installed"
        }
    }

    function Check-Winget {
        param([string]$Label, [string]$Id)
        if (Test-WingetInstalled -PackageId $Id) {
            log "${Label}: installed"
        } else {
            warn "${Label}: not installed"
        }
    }

    function Check-Path {
        param([string]$Label, [string]$Path)
        if (Test-Path $Path) { log "${Label}: found ($Path)" }
        else { warn "${Label}: not found" }
    }

    if (-not (Test-WingetAvailable)) {
        err "winget not available. Install 'App Installer' from the Microsoft Store."
    }

    section "System tools"
    Check-Cmd "git" "git"
    Check-Cmd "curl" "curl"
    Check-Cmd "jq" "jq"

    section "Shells & terminal"
    Check-Winget "PowerShell 7"       "Microsoft.PowerShell"
    Check-Winget "Windows Terminal"   "Microsoft.WindowsTerminal"

    section "Utilities"
    Check-Winget "7-Zip"              "7zip.7zip"
    Check-Winget "Notepad++"          "Notepad++.Notepad++"

    section "Modern CLI tools"
    Check-Cmd "bat"     "bat"
    Check-Cmd "ripgrep" "rg"
    Check-Cmd "fzf"     "fzf"
    Check-Cmd "eza"     "eza"

    section "Applications"
    Check-Cmd    "Google Chrome"         "chrome"
    Check-Winget "Visual Studio Code"    "Microsoft.VisualStudioCode"
    Check-Cmd    "GitHub CLI"            "gh"
    Check-Winget "DBeaver"               "dbeaver.dbeaver"
    Check-Winget "Beekeeper Studio"      "Beekeeper-Studio.Beekeeper-Studio"

    section "Languages & runtimes"
    Check-Cmd "Python 3" "python"
    Check-Path "pyenv-win" "$env:USERPROFILE\.pyenv"
    Check-Path "nvm-windows" "$env:ProgramFiles\nvm"
    Check-Cmd "Node.js"  "node"

    section "Docker & WSL"
    Check-Winget "Docker Desktop" "Docker.DockerDesktop"
    try {
        $wslStatus = wsl --status 2>&1 | Out-String
        if ($wslStatus -match "Default Version") {
            log "WSL: installed"
        } else {
            warn "WSL: not installed or not configured"
        }
    } catch {
        warn "WSL: not available"
    }

    section "Git config"
    $gitName  = (git config --global user.name  2>$null)
    $gitEmail = (git config --global user.email 2>$null)
    if ($gitName -and $gitEmail) {
        log "Git: `"$gitName`" <$gitEmail>"
    } else {
        warn "Git: user.name or user.email not set"
    }

    section "PowerShell profile"
    $p = Get-ProfilePath
    if (Test-Path $p) {
        log "Profile file: $p"
    } else {
        warn "Profile file: not created yet"
    }

    blank
    rule
    Write-Host "  Check complete. Run without -Check to install/update." -ForegroundColor Cyan
    rule
    exit 0
}

# =============================================================
#  INSTALL / UPDATE MODE
# =============================================================

# ── Prerequisites ─────────────────────────────────────────────
if (-not (Test-IsAdmin)) {
    err "This script must be run as Administrator (scope=machine installs require elevation)."
}

if (-not (Test-WingetAvailable)) {
    err "winget not available. Install 'App Installer' from the Microsoft Store, then re-run."
}

log "Running as Administrator."
log "winget is available."

# Refresh sources once upfront; winget may prompt for agreements otherwise.
info "Refreshing winget sources..."
winget source update --disable-interactivity | Out-Null
log  "winget sources refreshed."

# ── 1. System tools ───────────────────────────────────────────
section "System tools"
# Git for Windows, curl (native on modern Win), jq (useful for scripting)
Install-WingetPackage -Id "Git.Git"             -Label "Git for Windows"   | Out-Null
Install-WingetPackage -Id "jqlang.jq"           -Label "jq"                | Out-Null

# ── 2. Shells & terminal ──────────────────────────────────────
section "Shells & terminal"
Install-WingetPackage -Id "Microsoft.PowerShell"     -Label "PowerShell 7"     | Out-Null
Install-WingetPackage -Id "Microsoft.WindowsTerminal" -Label "Windows Terminal" | Out-Null

# ── 3. General utilities ──────────────────────────────────────
section "General utilities"
Install-WingetPackage -Id "7zip.7zip"                -Label "7-Zip"        | Out-Null
Install-WingetPackage -Id "Notepad++.Notepad++"      -Label "Notepad++"    | Out-Null

# ── 4. Modern CLI tools ───────────────────────────────────────
section "Modern CLI tools"
Install-WingetPackage -Id "sharkdp.bat"              -Label "bat"          | Out-Null
Install-WingetPackage -Id "BurntSushi.ripgrep.MSVC"  -Label "ripgrep"      | Out-Null
Install-WingetPackage -Id "junegunn.fzf"             -Label "fzf"          | Out-Null
Install-WingetPackage -Id "eza-community.eza"        -Label "eza"          | Out-Null

# Refresh PATH so newly-installed tools are visible in this session
Update-EnvPath

# ── 5. Browsers & editors ─────────────────────────────────────
section "Browsers & editors"
Install-WingetPackage -Id "Google.Chrome"                 -Label "Google Chrome"       | Out-Null
Install-WingetPackage -Id "Microsoft.VisualStudioCode"    -Label "Visual Studio Code"  | Out-Null

# ── 6. GitHub CLI ─────────────────────────────────────────────
section "GitHub CLI"
Install-WingetPackage -Id "GitHub.cli" -Label "GitHub CLI (gh)" | Out-Null

# ── 7. Database tools ─────────────────────────────────────────
section "Database tools"
Install-WingetPackage -Id "dbeaver.dbeaver"                  -Label "DBeaver"           | Out-Null
Install-WingetPackage -Id "Beekeeper-Studio.Beekeeper-Studio" -Label "Beekeeper Studio" | Out-Null

# ── 8. Python + pyenv-win ─────────────────────────────────────
section "Python + pyenv-win"
# Baseline Python for quick scripts; pyenv-win manages multiple versions.
Install-WingetPackage -Id "Python.Python.3.12" -Label "Python 3.12" | Out-Null

# pyenv-win: install via its official one-liner if not already present
$PyenvDir = Join-Path $env:USERPROFILE ".pyenv"
if (-not (Test-Path $PyenvDir)) {
    info "Installing pyenv-win..."
    try {
        # Download and execute the official installer in a subshell.
        # pyenv-win modifies the user's PATH and creates PYENV env vars.
        Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1" `
            -OutFile "$env:TEMP\install-pyenv-win.ps1"
        & "$env:TEMP\install-pyenv-win.ps1"
        Remove-Item "$env:TEMP\install-pyenv-win.ps1" -Force -ErrorAction SilentlyContinue
        log "pyenv-win installed."
    } catch {
        warn "pyenv-win installation failed: $_"
    }
} else {
    warn "pyenv-win already present at $PyenvDir, skipped."
}

# ── 9. Node.js via nvm-windows ────────────────────────────────
section "Node.js via nvm-windows"
$nvmInstalled = Test-WingetInstalled -PackageId "CoreyButler.NVMforWindows"
$nvmJustInstalled = $false

if (-not $nvmInstalled) {
    if (Install-WingetPackage -Id "CoreyButler.NVMforWindows" -Label "nvm-windows") {
        $nvmJustInstalled = $true
    }
} else {
    warn "nvm-windows: already installed, skipped."
}

# Refresh PATH to pick up nvm
Update-EnvPath

# Install Node LTS only on first install (mirrors bash $INSTALL_NODE logic)
if ($nvmJustInstalled) {
    if (Get-Command nvm -ErrorAction SilentlyContinue) {
        info "Installing latest Node.js LTS via nvm..."
        try {
            & nvm install lts
            & nvm use lts
            log "Node.js LTS installed."
        } catch {
            warn "nvm LTS install failed: $_. Run 'nvm install lts' manually after restarting your shell."
        }
    } else {
        warn "nvm not on PATH yet. Open a new terminal and run: nvm install lts"
    }
} else {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVer = (& node --version 2>$null)
        log "Node.js already active: $nodeVer"
    } else {
        warn "nvm present but no Node version active. Run 'nvm install lts' manually if needed."
    }
}

# ── 10. Docker Desktop (requires WSL2) ────────────────────────
if (-not $SkipDocker) {
    section "Docker Desktop"
    Install-WingetPackage -Id "Docker.DockerDesktop" -Label "Docker Desktop" | Out-Null
    warn "Docker Desktop requires WSL2 and a reboot to be fully functional."
    warn "First launch: open Docker Desktop manually to complete setup."
} else {
    warn "Skipping Docker Desktop (-SkipDocker)"
}

# ── 11. WSL2 + Ubuntu ─────────────────────────────────────────
if (-not $SkipWSL) {
    section "WSL2 + Ubuntu"
    # `wsl --status` returns non-zero if WSL is not installed
    $wslOk = $false
    try {
        $null = & wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) { $wslOk = $true }
    } catch { $wslOk = $false }

    if (-not $wslOk) {
        info "Installing WSL2 + Ubuntu (this may take a while)..."
        try {
            # --no-launch prevents the interactive first-run prompt during setup.
            # User will need to create a UNIX username/password on first `wsl` launch.
            wsl --install --distribution Ubuntu --no-launch
            log "WSL2 + Ubuntu installed. A reboot is required before first use."
        } catch {
            warn "WSL install failed: $_. Try manually: wsl --install"
        }
    } else {
        warn "WSL already installed, skipped."
        # Check if Ubuntu distro is present
        $distros = (wsl --list --quiet 2>$null) -join " "
        if ($distros -notmatch "Ubuntu") {
            info "WSL is installed but Ubuntu distro not found. Installing..."
            try {
                wsl --install --distribution Ubuntu --no-launch
                log "Ubuntu distro installed."
            } catch {
                warn "Ubuntu install failed: $_"
            }
        }
    }
} else {
    warn "Skipping WSL2 (-SkipWSL)"
}

# ── 12. PowerShell profile customization ──────────────────────
section "PowerShell profile (`$PROFILE.CurrentUserAllHosts)"
Update-EnvPath  # make sure eza/bat/etc. are visible when we test below

# 'update' alias equivalent (Windows version): winget upgrade all
Add-ProfileBlock -Label "alias 'update'" -Marker "function update" -Block @"

# System update shortcut
function update {
    winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
}
"@

# eza aliases (overriding ls/ll/tree)
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Add-ProfileBlock -Label "eza aliases" -Marker "# eza as ls replacement" -Block @"

# eza as ls replacement
Set-Alias -Name ls   -Value eza -Option AllScope -Force
function ll   { eza --icons -lah @args }
function tree { eza --icons --tree @args }
"@
}

# pyenv-win init: add env vars and PATH if not already present.
# pyenv-win's installer normally does this, but we guard in case of partial installs.
if (Test-Path $PyenvDir) {
    Add-ProfileBlock -Label "pyenv-win init" -Marker "PYENV_HOME" -Block @"

# pyenv-win
`$env:PYENV         = "`$env:USERPROFILE\.pyenv\pyenv-win"
`$env:PYENV_HOME    = `$env:PYENV
`$env:PYENV_ROOT    = `$env:PYENV
if (`$env:Path -notlike "*`$env:PYENV\bin*") {
    `$env:Path = "`$env:PYENV\bin;`$env:PYENV\shims;`$env:Path"
}
"@
}

# ── 13. Git global config ─────────────────────────────────────
section "Git global config"
if (Get-Command git -ErrorAction SilentlyContinue) {
    $currentName  = (git config --global user.name  2>$null)
    $currentEmail = (git config --global user.email 2>$null)

    if ($currentName -and $currentEmail) {
        log "Git already configured: `"$currentName`" <$currentEmail>"
    } else {
        $gitUsername = Read-Host "  GitHub username"
        $gitEmail    = Read-Host "  GitHub email"
        git config --global user.name  $gitUsername
        git config --global user.email $gitEmail
        log "Git configured: `"$gitUsername`" <$gitEmail>"
    }
} else {
    warn "git not on PATH yet (was just installed). Open a new terminal and run:"
    warn "  git config --global user.name  `"Your Name`""
    warn "  git config --global user.email `"you@example.com`""
}

# ── 14. Summary ───────────────────────────────────────────────
blank
rule
Write-Host "  Setup complete! Summary:" -ForegroundColor Cyan
rule
Write-Host "  [OK] Git, jq" -ForegroundColor Green
Write-Host "  [OK] PowerShell 7 + Windows Terminal" -ForegroundColor Green
Write-Host "  [OK] 7-Zip + Notepad++" -ForegroundColor Green
Write-Host "  [OK] bat, ripgrep, fzf, eza" -ForegroundColor Green
Write-Host "  [OK] Chrome + VSCode" -ForegroundColor Green
Write-Host "  [OK] GitHub CLI" -ForegroundColor Green
Write-Host "  [OK] DBeaver + Beekeeper Studio" -ForegroundColor Green
Write-Host "  [OK] Python + pyenv-win" -ForegroundColor Green
Write-Host "  [OK] nvm-windows + Node.js LTS" -ForegroundColor Green
if (-not $SkipDocker) { Write-Host "  [OK] Docker Desktop" -ForegroundColor Green }
if (-not $SkipWSL)    { Write-Host "  [OK] WSL2 + Ubuntu" -ForegroundColor Green }
Write-Host "  [OK] PowerShell profile aliases" -ForegroundColor Green
blank
Write-Host "  [!] Action items:" -ForegroundColor Yellow
Write-Host "      - Open a NEW terminal (or run: . `$PROFILE) to activate aliases and pyenv" -ForegroundColor Yellow
if (-not $SkipDocker) {
    Write-Host "      - Reboot, then launch Docker Desktop to complete first-run setup" -ForegroundColor Yellow
}
if (-not $SkipWSL) {
    Write-Host "      - Reboot, then run 'wsl' to finish Ubuntu user setup" -ForegroundColor Yellow
}
rule
blank

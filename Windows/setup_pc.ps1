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

# ── Config ────────────────────────────────────────────────────
# Python version installed via the Python Install Manager on a fresh machine.
# Pinned on purpose (not "latest 3"): a too-recent release can ship breaking API
# changes or land before key packages support it. Bump this when you're ready.
$PythonVersion = "3.13"

# ── Helpers ───────────────────────────────────────────────────
function log     { param($m) Write-Host " [OK] $m" -ForegroundColor Green }
function warn    { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function info    { param($m) Write-Host "  [i] $m" -ForegroundColor Cyan }
function err     { param($m) Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }
function rule    { Write-Host ("=" * 65) -ForegroundColor DarkGray }
function section { param($m) Write-Host ""; Write-Host "> $m" -ForegroundColor Cyan -BackgroundColor Black }
function blank   { Write-Host "" }

# ── Result tracking ───────────────────────────────────────────
# Every install step records its real outcome here so the final summary
# reflects what actually happened instead of a hardcoded "all good" list.
$script:Results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("ok", "fail", "skip")][string]$Status,
        [string]$Detail = ""
    )
    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

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
        [string]$Scope = "machine",
        [string]$CommandName   # optional CLI command that proves it's already present
    )
    # Detect existing installs two ways: a CLI command on PATH (catches tools
    # installed outside winget, e.g. a Git installed from the official .exe) and
    # winget's own list. Without the command check, winget reinstalls a tool it
    # didn't itself install.
    if ($CommandName -and (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        warn "${Label}: already present ('$CommandName' on PATH), skipped."
        Add-Result $Label "ok" "already present"
        return $false
    }
    if (Test-WingetInstalled -PackageId $Id) {
        warn "${Label}: already installed, skipped."
        Add-Result $Label "ok" "already present"
        return $false
    }

    info "${Label}: installing (id=$Id, scope=$Scope)..."
    # --silent: no UI   --accept-*: skip interactive prompts
    winget install --id $Id --exact --scope $Scope `
        --silent --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
    # Many packages ship only a user-scoped (or unscoped) installer; forcing
    # --scope machine then fails with NO_APPLICABLE_INSTALLER / NO_APPLICATIONS_FOUND.
    # Retry once letting winget pick the scope before declaring failure.
    if ($LASTEXITCODE -ne 0) {
        warn "${Label}: scope=$Scope failed (exit $LASTEXITCODE), retrying without explicit scope..."
        winget install --id $Id --exact `
            --silent --accept-package-agreements --accept-source-agreements `
            --disable-interactivity
    }

    if ($LASTEXITCODE -eq 0) {
        log  "${Label}: installed."
        Add-Result $Label "ok" "installed"
        return $true
    } else {
        warn "${Label}: winget exit code $LASTEXITCODE (install failed)."
        Add-Result $Label "fail" "winget exit $LASTEXITCODE"
        return $false
    }
}

# ── PowerShell profile helpers (equivalent of .bashrc handling) ──
# We target BOTH Windows PowerShell 5.1 and PowerShell 7 so the same aliases and
# predictions load whichever you open. $PROFILE reflects the real Documents
# location (incl. OneDrive redirection), so derive both profiles from it: the
# AllHosts profile path is "<Documents>\WindowsPowerShell\profile.ps1" (5.1) or
# "<Documents>\PowerShell\profile.ps1" (7), differing only by that folder name.
function Get-ProfilePaths {
    $docs = Split-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) -Parent
    return @(
        (Join-Path $docs "WindowsPowerShell\profile.ps1"),   # Windows PowerShell 5.1
        (Join-Path $docs "PowerShell\profile.ps1")            # PowerShell 7+
    )
}

# Short label for messages: the edition folder name (WindowsPowerShell / PowerShell).
function Get-ProfileEdition { param([string]$Path) Split-Path (Split-Path $Path -Parent) -Leaf }

function Ensure-ProfileFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        # -Force creates any missing parent folders (e.g. Documents\PowerShell).
        New-Item -ItemType File -Path $Path -Force | Out-Null
        log "Created PowerShell profile: $Path"
    }
    return $Path
}

# Append a block to every target profile, each only if its marker isn't present.
# Mirrors the bash `grep -q ... || append` pattern.
function Add-ProfileBlock {
    param(
        [Parameter(Mandatory)][string]$Marker,   # regex / literal string to search for
        [Parameter(Mandatory)][string]$Block,    # content to append (leading newline added)
        [string]$Label = "profile block"
    )
    foreach ($profilePath in Get-ProfilePaths) {
        Ensure-ProfileFile -Path $profilePath | Out-Null
        $edition = Get-ProfileEdition $profilePath
        $current = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($null -eq $current) { $current = "" }

        if ($current -match [regex]::Escape($Marker)) {
            warn "${Label}: already in $edition profile, skipped."
            continue
        }

        # Ensure the file ends with a newline before appending (mirrors ensure_bashrc_newline)
        if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) {
            Add-Content -Path $profilePath -Value ""
        }

        Add-Content -Path $profilePath -Value $Block
        log "${Label}: added to $edition profile."
    }
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

# ── nvm-windows helpers ───────────────────────────────────────
# Resolve the nvm executable and make it usable in THIS session. Right after a
# winget install nvm isn't on PATH yet, and winget installs it under
# %LOCALAPPDATA%\nvm (recorded in NVM_HOME) -- not Program Files. We also load the
# persisted NVM_HOME / NVM_SYMLINK into the session (it may predate the install)
# and put them on PATH so 'nvm install/use' work. Returns the exe path or $null.
function Resolve-NvmExe {
    # Load persisted nvm env vars into the current process if missing.
    foreach ($v in "NVM_HOME", "NVM_SYMLINK") {
        if (-not [Environment]::GetEnvironmentVariable($v, "Process")) {
            $persisted = [Environment]::GetEnvironmentVariable($v, "Machine")
            if (-not $persisted) { $persisted = [Environment]::GetEnvironmentVariable($v, "User") }
            if ($persisted) { [Environment]::SetEnvironmentVariable($v, $persisted, "Process") }
        }
    }
    $cmd = Get-Command nvm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @($env:NVM_HOME, (Join-Path $env:LOCALAPPDATA "nvm"), (Join-Path $env:ProgramFiles "nvm"))) {
        if ($dir -and (Test-Path (Join-Path $dir "nvm.exe"))) {
            # Ensure nvm + its symlink dir are on PATH for this session.
            if ($env:NVM_HOME    -and $env:Path -notlike "*$env:NVM_HOME*")    { $env:Path = "$env:NVM_HOME;$env:Path" }
            if ($env:NVM_SYMLINK -and $env:Path -notlike "*$env:NVM_SYMLINK*") { $env:Path = "$env:NVM_SYMLINK;$env:Path" }
            return (Join-Path $dir "nvm.exe")
        }
    }
    return $null
}

# Install + activate the latest Node LTS via nvm and record the result.
function Install-NodeLts {
    param([Parameter(Mandatory)][string]$NvmExe)
    info "Installing latest Node.js LTS via nvm..."
    try {
        & $NvmExe install lts
        & $NvmExe use lts
        log "Node.js LTS installed."
        Add-Result "Node.js (LTS via nvm)" "ok" "installed"
    } catch {
        warn "nvm LTS install failed: $_. Run 'nvm install lts' after reopening your shell."
        Add-Result "Node.js (LTS via nvm)" "fail" "$_"
    }
}

# ── Install a PowerShell Gallery module idempotently ──────────
# Skips the install if the module is already available. Uses -Force to avoid the
# "untrusted repository" prompt.
#
# -Scope AllUsers installs into C:\Program Files\WindowsPowerShell\Modules, which
# is on the default module path of BOTH Windows PowerShell 5.1 and PowerShell 7,
# so a module installed there is visible to both editions. For AllUsers we check
# presence by that path (not Get-Module -ListAvailable) so a copy sitting only in
# the CurrentUser path doesn't mask the need for the shared one.
function Install-PSModuleIfMissing {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinimumVersion,
        [ValidateSet("CurrentUser", "AllUsers")][string]$Scope = "CurrentUser"
    )
    if ($Scope -eq "AllUsers") {
        $shared  = Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$Name"
        $present = Test-Path $shared
    } else {
        $available = Get-Module -ListAvailable -Name $Name
        if ($MinimumVersion -and $available) {
            $available = $available | Where-Object { $_.Version -ge [version]$MinimumVersion }
        }
        $present = [bool]$available
    }
    if ($present) {
        warn "${Name}: already available ($Scope), skipped."
        Add-Result $Name "ok" "already present"
        return
    }
    info "${Name}: installing from PSGallery ($Scope)..."
    # TLS 1.2 for older hosts (Windows PowerShell 5.1); harmless on PowerShell 7.
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
    try {
        Install-Module -Name $Name -Scope $Scope -Force -AllowClobber `
            -Repository PSGallery -ErrorAction Stop
        log "${Name}: installed ($Scope)."
        Add-Result $Name "ok" "installed"
    } catch {
        warn "${Name}: install failed ($_). Run manually: Install-Module $Name -Scope $Scope"
        Add-Result $Name "fail" "$_"
    }
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

    section "Shell experience"
    function Check-Module {
        param([string]$Label, [string]$Name)
        if (Get-Module -ListAvailable -Name $Name) { log "${Label}: installed" }
        else { warn "${Label}: not installed" }
    }
    Check-Module "PSReadLine"          "PSReadLine"
    Check-Module "posh-git"            "posh-git"
    Check-Module "CompletionPredictor" "CompletionPredictor"

    section "Utilities"
    Check-Winget "7-Zip"              "7zip.7zip"
    Check-Winget "Notepad++"          "Notepad++.Notepad++"

    section "Modern CLI tools"
    Check-Cmd "bat"     "bat"
    Check-Cmd "ripgrep" "rg"
    Check-Cmd "fzf"     "fzf"
    Check-Cmd "eza"     "eza"

    section "Applications"
    Check-Winget "Google Chrome"         "Google.Chrome"
    Check-Winget "Visual Studio Code"    "Microsoft.VisualStudioCode"
    Check-Cmd    "GitHub CLI"            "gh"
    Check-Winget "DBeaver"               "DBeaver.DBeaver.Community"
    Check-Winget "Beekeeper Studio"      "beekeeper-studio.beekeeper-studio"

    section "Languages & runtimes"
    Check-Cmd    "Python 3"               "python"
    Check-Winget "Python Install Manager" "Python.PythonInstallManager"

    # Node is managed by nvm-windows. Flag a standalone Node (no nvm) because a
    # full run will uninstall it and reinstall Node via nvm (see section 9).
    $nvmPresent = Test-WingetInstalled -PackageId "CoreyButler.NVMforWindows"
    if ($nvmPresent) { log  "nvm-windows: installed" }
    else             { warn "nvm-windows: not installed" }

    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVer = (& node --version 2>$null)
        if ($nvmPresent) {
            log "Node.js: $nodeVer (managed by nvm)"
        } else {
            warn "Node.js: $nodeVer found WITHOUT nvm -- a full run will UNINSTALL it and reinstall via nvm-windows."
        }
    } else {
        warn "Node.js: not installed"
    }

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
    foreach ($p in Get-ProfilePaths) {
        $edition = Get-ProfileEdition $p
        if (Test-Path $p) { log  "Profile ($edition): $p" }
        else              { warn "Profile ($edition): not created yet" }
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
Install-WingetPackage -Id "Git.Git"   -Label "Git for Windows" -CommandName "git" | Out-Null
Install-WingetPackage -Id "jqlang.jq" -Label "jq"              -CommandName "jq"  | Out-Null

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
Install-WingetPackage -Id "sharkdp.bat"             -Label "bat"     -CommandName "bat" | Out-Null
Install-WingetPackage -Id "BurntSushi.ripgrep.MSVC" -Label "ripgrep" -CommandName "rg"  | Out-Null
Install-WingetPackage -Id "junegunn.fzf"            -Label "fzf"     -CommandName "fzf" | Out-Null
Install-WingetPackage -Id "eza-community.eza"       -Label "eza"     -CommandName "eza" | Out-Null

# Refresh PATH so newly-installed tools are visible in this session
Update-EnvPath

# ── 5. Browsers & editors ─────────────────────────────────────
section "Browsers & editors"
Install-WingetPackage -Id "Google.Chrome"                 -Label "Google Chrome"       | Out-Null
Install-WingetPackage -Id "Microsoft.VisualStudioCode"    -Label "Visual Studio Code"  | Out-Null

# ── 6. GitHub CLI ─────────────────────────────────────────────
section "GitHub CLI"
Install-WingetPackage -Id "GitHub.cli" -Label "GitHub CLI (gh)" -CommandName "gh" | Out-Null

# ── 7. Database tools ─────────────────────────────────────────
section "Database tools"
# NOTE: winget --exact is case-sensitive, so these ids must match winget exactly.
Install-WingetPackage -Id "DBeaver.DBeaver.Community"          -Label "DBeaver"          | Out-Null
Install-WingetPackage -Id "beekeeper-studio.beekeeper-studio" -Label "Beekeeper Studio" | Out-Null

# ── 8. Python via the Python Install Manager ──────────────────
# The Python Install Manager (py install / py list) is the official, recommended
# way to manage Python on Windows. One manager only: no winget baseline Python,
# no pyenv-win. We install the pinned $PythonVersion if no runtime exists yet
# (mirrors 'nvm install lts' on first install); add more later with `py install`.
section "Python (Python Install Manager)"
Install-WingetPackage -Id "Python.PythonInstallManager" -Label "Python Install Manager" | Out-Null
Update-EnvPath

$pyCmd = Get-Command py -ErrorAction SilentlyContinue
$pyExe = if ($pyCmd) { $pyCmd.Source } else { $null }
if ($pyExe) {
    # Idempotent: only install a runtime when none exists. 'py list --format=json'
    # returns a .versions array we can inspect.
    $hasPython = $false
    try {
        $pyJson = (& $pyExe list --format=json 2>$null | Out-String)
        if ($pyJson) {
            $parsed = $pyJson | ConvertFrom-Json
            if ($parsed.versions -and @($parsed.versions).Count -gt 0) { $hasPython = $true }
        }
    } catch { $hasPython = $false }

    if ($hasPython) {
        warn "Python already installed (managed by the Install Manager), skipped."
        Add-Result "Python" "ok" "existing runtime kept"
    } else {
        info "Installing Python $PythonVersion via the Install Manager..."
        & $pyExe install $PythonVersion --yes
        if ($LASTEXITCODE -eq 0) {
            log "Python $PythonVersion installed."
            Add-Result "Python $PythonVersion" "ok" "installed"
        } else {
            warn "py install $PythonVersion exited $LASTEXITCODE. Run manually: py install $PythonVersion"
            Add-Result "Python $PythonVersion" "fail" "py install exit $LASTEXITCODE"
        }
    }
} else {
    warn "Python Install Manager not on PATH yet. Open a NEW terminal and run: py install $PythonVersion"
    Add-Result "Python $PythonVersion" "skip" "reopen shell, then 'py install $PythonVersion'"
}

# ── 9. Node.js via nvm-windows ────────────────────────────────
# Order matters: install nvm-windows and confirm it's usable BEFORE removing any
# standalone Node, otherwise a failed nvm install leaves the machine with no Node
# at all (which is exactly what a naive "remove then install" caused).
section "Node.js via nvm-windows"
$nvmWasInstalled = Test-WingetInstalled -PackageId "CoreyButler.NVMforWindows"

if ($nvmWasInstalled) {
    warn "nvm-windows: already installed, skipped."
    Add-Result "nvm-windows" "ok" "already present"
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVer = (& node --version 2>$null)
        log "Node.js already active: $nodeVer"
        Add-Result "Node.js (via nvm)" "ok" $nodeVer
    } else {
        # nvm is installed but no Node is active (e.g. a previous run installed nvm
        # but the LTS step couldn't run because nvm wasn't on PATH yet). Install it
        # now so a re-run converges to a working Node instead of only warning.
        $nvmExe = Resolve-NvmExe
        if ($nvmExe) {
            Install-NodeLts -NvmExe $nvmExe
        } else {
            warn "nvm present but not on PATH yet. Open a NEW terminal and run: nvm install lts"
            Add-Result "Node.js (LTS via nvm)" "skip" "reopen shell, then 'nvm install lts'"
        }
    }
} else {
    # 1) Install nvm-windows (records its own result; retries scope internally).
    $nvmOk = Install-WingetPackage -Id "CoreyButler.NVMforWindows" -Label "nvm-windows"
    Update-EnvPath
    $nvmExe = Resolve-NvmExe

    if ($nvmExe) {
        # 2) Now that nvm can take over, remove a conflicting standalone Node
        #    (direct MSI / winget) that owns C:\Program Files\nodejs and the PATH.
        if (Get-Command node -ErrorAction SilentlyContinue) {
            $existingNode = (& node --version 2>$null)
            warn "Removing standalone Node.js $existingNode so nvm-windows can manage Node cleanly..."
            $removed = $false
            foreach ($pkg in @("OpenJS.NodeJS", "OpenJS.NodeJS.LTS")) {
                if (Test-WingetInstalled -PackageId $pkg) {
                    winget uninstall --id $pkg --exact --silent `
                        --accept-source-agreements --disable-interactivity | Out-Null
                    if ($LASTEXITCODE -eq 0) { $removed = $true; break }
                }
            }
            if (-not $removed) {
                winget uninstall --name "Node.js" --silent `
                    --accept-source-agreements --disable-interactivity | Out-Null
                if ($LASTEXITCODE -eq 0) { $removed = $true }
            }
            if ($removed) {
                # A leftover real C:\Program Files\nodejs dir blocks nvm's symlink.
                $nodeDir = Join-Path $env:ProgramFiles "nodejs"
                if ((Test-Path $nodeDir) -and `
                    -not (Get-ChildItem $nodeDir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                Update-EnvPath
                log "Standalone Node.js removed."
            } else {
                warn "Could not auto-remove the standalone Node.js; nvm may conflict until it's removed."
            }
        }

        # 3) Install the latest LTS through nvm.
        Install-NodeLts -NvmExe $nvmExe
    } else {
        # nvm not usable in this session → leave any existing Node untouched.
        if ($nvmOk) {
            warn "nvm-windows installed but not on PATH yet. Open a NEW terminal and re-run, or run: nvm install lts"
            Add-Result "Node.js (LTS via nvm)" "skip" "reopen shell, then re-run or 'nvm install lts'"
        } else {
            warn "nvm-windows install failed; leaving any existing Node.js untouched."
            Add-Result "Node.js (LTS via nvm)" "fail" "nvm install failed"
        }
    }
}

# ── 10. WSL2 + Ubuntu (before Docker: Docker Desktop needs WSL2) ──
if (-not $SkipWSL) {
    section "WSL2 + Ubuntu"
    # wsl.exe lives in System32 but may not be on this session's PATH; resolve it
    # explicitly so a bare 'wsl' that isn't on PATH doesn't abort the step.
    $wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $wslExe = if ($wslCmd) { $wslCmd.Source } else { $null }
    if (-not $wslExe) {
        $candidate = Join-Path $env:SystemRoot "System32\wsl.exe"
        if (Test-Path $candidate) { $wslExe = $candidate }
    }

    if (-not $wslExe) {
        # No wsl.exe at all (feature never enabled): turn the optional features on
        # so a reboot + re-run (or `wsl --install`) can finish the job.
        warn "wsl.exe not found. Enabling WSL optional features (reboot required)..."
        try {
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            warn "WSL features enabled. Reboot, then re-run this script (or run: wsl --install)."
            Add-Result "WSL2 + Ubuntu" "skip" "features enabled; reboot then re-run"
        } catch {
            warn "Could not enable WSL features: $_"
            Add-Result "WSL2 + Ubuntu" "fail" "$_"
        }
    } else {
        $wslOk = $false
        try {
            $null = & $wslExe --status 2>&1
            if ($LASTEXITCODE -eq 0) { $wslOk = $true }
        } catch { $wslOk = $false }

        if (-not $wslOk) {
            info "Installing WSL2 + Ubuntu (this may take a while)..."
            try {
                # --no-launch skips the interactive first-run; the user creates a
                # UNIX username/password on the first `wsl` launch after reboot.
                & $wslExe --install --distribution Ubuntu --no-launch
                $wslCode = $LASTEXITCODE
                if ($wslCode -eq 0) {
                    log "WSL2 + Ubuntu installed. A reboot is required before first use."
                    Add-Result "WSL2 + Ubuntu" "ok" "installed (reboot required)"
                } else {
                    # The Ubuntu download hits MS servers and can fail transiently
                    # (e.g. a 504). Fall back to installing just the WSL platform so
                    # a reboot + retry only needs the distro, not the whole feature.
                    warn "wsl --install -d Ubuntu failed (exit $wslCode; often a transient server error). Installing the WSL platform only..."
                    & $wslExe --install --no-distribution
                    if ($LASTEXITCODE -eq 0) {
                        warn "WSL2 platform installed. After reboot, add the distro with: wsl --install -d Ubuntu"
                        Add-Result "WSL2 + Ubuntu" "fail" "platform ok; retry distro: wsl --install -d Ubuntu"
                    } else {
                        warn "WSL install failed. Try manually: wsl --install"
                        Add-Result "WSL2 + Ubuntu" "fail" "wsl --install exit $wslCode"
                    }
                }
            } catch {
                warn "WSL install failed: $_. Try manually: wsl --install"
                Add-Result "WSL2 + Ubuntu" "fail" "$_"
            }
        } else {
            warn "WSL already installed, skipped."
            $distros = (& $wslExe --list --quiet 2>$null) -join " "
            if ($distros -notmatch "Ubuntu") {
                info "WSL present but Ubuntu distro not found. Installing..."
                try {
                    & $wslExe --install --distribution Ubuntu --no-launch
                    log "Ubuntu distro installed."
                } catch {
                    warn "Ubuntu install failed: $_"
                }
            }
            Add-Result "WSL2 + Ubuntu" "ok" "already present"
        }
    }
} else {
    warn "Skipping WSL2 (-SkipWSL)"
    Add-Result "WSL2 + Ubuntu" "skip" "-SkipWSL"
}

# ── 11. Docker Desktop (requires WSL2, installed above) ────────
if (-not $SkipDocker) {
    section "Docker Desktop"
    Install-WingetPackage -Id "Docker.DockerDesktop" -Label "Docker Desktop" | Out-Null
    warn "Docker Desktop requires WSL2 and a reboot to be fully functional."
    warn "First launch: open Docker Desktop manually to complete setup."
} else {
    warn "Skipping Docker Desktop (-SkipDocker)"
    Add-Result "Docker Desktop" "skip" "-SkipDocker"
}

# ── 12. Smart shell modules (PSReadLine predictions + git completion) ──
section "Smart shell (PSReadLine + posh-git)"
# PSReadLine: PowerShell 7 already bundles 2.3+, so we only need a CurrentUser
# copy for Windows PowerShell 5.1 (which ships 2.0, below the 2.2.0 floor for
# plugin-based predictions). CurrentUser also dodges the "file in use" error
# from overwriting the PSReadLine that's loaded in this very session.
Install-PSModuleIfMissing -Name "PSReadLine" -MinimumVersion "2.2.0" -Scope CurrentUser
# posh-git + CompletionPredictor go to AllUsers so BOTH 5.1 and PowerShell 7 see
# them (the CurrentUser paths differ between the two editions).
# posh-git: git-aware tab completion (branch names, remotes, ...) + status prompt.
Install-PSModuleIfMissing -Name "posh-git" -Scope AllUsers
# CompletionPredictor: IntelliSense-based predictions feeding PSReadLine.
Install-PSModuleIfMissing -Name "CompletionPredictor" -Scope AllUsers

# ── 13. PowerShell profile customization ──────────────────────
section "PowerShell profile (Windows PowerShell 5.1 + PowerShell 7)"
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

# Smart shell: zsh-like history/plugin autosuggestions + git-aware tab completion.
# Guarded so the profile never errors if a module is missing on a given machine.
Add-ProfileBlock -Label "smart shell (PSReadLine)" -Marker "# Smart shell: PSReadLine" -Block @"

# Smart shell: PSReadLine predictions + git-aware completion
if (Get-Module -ListAvailable PSReadLine | Where-Object { `$_.Version -ge [version]'2.2.0' }) {
    Import-Module PSReadLine
    # Predictions need PowerShell 7.2+ for the 'Plugin' source, and an interactive
    # VT-capable console. Wrap in try/catch: these throw (not catchable via
    # -ErrorAction) when output is redirected or the host lacks VT support.
    try {
        if (`$PSVersionTable.PSVersion -ge [version]'7.2') {
            Set-PSReadLineOption -PredictionSource HistoryAndPlugin
            if (Get-Module -ListAvailable CompletionPredictor) { Import-Module CompletionPredictor }
        } else {
            Set-PSReadLineOption -PredictionSource History
        }
        Set-PSReadLineOption -PredictionViewStyle ListView
    } catch {}
}
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
if (Get-Module -ListAvailable posh-git) { Import-Module posh-git }
"@

Add-Result "PowerShell profile" "ok" "aliases + smart shell"

# ── 14. Git global config ─────────────────────────────────────
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

# ── 15. Summary ───────────────────────────────────────────────
# Built from the real outcomes recorded during the run, not a fixed list.
blank
rule
Write-Host "  Setup finished - actual results:" -ForegroundColor Cyan
rule

$okItems   = @($script:Results | Where-Object { $_.Status -eq "ok" })
$skipItems = @($script:Results | Where-Object { $_.Status -eq "skip" })
$failItems = @($script:Results | Where-Object { $_.Status -eq "fail" })

foreach ($r in $okItems) {
    $d = if ($r.Detail) { " ($($r.Detail))" } else { "" }
    Write-Host "  [OK] $($r.Name)$d" -ForegroundColor Green
}
foreach ($r in $skipItems) {
    $d = if ($r.Detail) { " ($($r.Detail))" } else { "" }
    Write-Host "  [--] $($r.Name)$d" -ForegroundColor DarkGray
}
foreach ($r in $failItems) {
    $d = if ($r.Detail) { " ($($r.Detail))" } else { "" }
    Write-Host "  [X] $($r.Name)$d" -ForegroundColor Red
}

blank
Write-Host ("  Totals: {0} ok, {1} failed, {2} skipped." -f `
    $okItems.Count, $failItems.Count, $skipItems.Count) -ForegroundColor Cyan

blank
Write-Host "  [!] Action items:" -ForegroundColor Yellow
Write-Host "      - Open a NEW terminal (or run: . `$PROFILE) to activate aliases" -ForegroundColor Yellow
Write-Host "      - Add more Python versions any time: py install 3.13  (py list to see them)" -ForegroundColor Yellow
if ($failItems.Count -gt 0) {
    Write-Host "      - Re-run the script to retry the failed items above (winget can be locked/flaky mid-run)" -ForegroundColor Yellow
}
if (-not $SkipDocker) {
    Write-Host "      - Reboot, then launch Docker Desktop to complete first-run setup" -ForegroundColor Yellow
}
if (-not $SkipWSL) {
    Write-Host "      - Reboot, then run 'wsl' to finish Ubuntu user setup" -ForegroundColor Yellow
}
rule
blank

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Add "Open in Windows Terminal Here" to the right-click menu
# Supports both background (empty area) and folder right-click
#
# Usage:
#   .\Install-WTContextMenu.ps1            -> Install context menu entries
#   .\Install-WTContextMenu.ps1 -Uninstall -> Remove context menu entries
#
# No elevation required (writes to HKCU).
# The script is idempotent: re-running it is always safe.
# ============================================================

param (
    [switch]$Uninstall
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step  ([string]$msg) { Write-Host "   $msg" }
function Write-Ok    ([string]$msg) { Write-Host "   ✅ $msg" -ForegroundColor Green }
function Write-Warn  ([string]$msg) { Write-Host "   ⚠️  $msg" -ForegroundColor Yellow }
function Write-Fail  ([string]$msg) { Write-Host "   ❌ $msg" -ForegroundColor Red }
function Write-Header([string]$msg) { Write-Host $msg }

<#
.SYNOPSIS
    Sets a registry key property, creating the key if it does not exist.
    Returns $true if a change was actually written, $false when the value
    was already correct (idempotent no-op).
#>
function Set-RegistryValue {
    param (
        [string]$KeyPath,
        [string]$Name,
        [string]$Value
    )

    # Create key if missing
    if (-not (Test-Path $KeyPath)) {
        New-Item -Path $KeyPath -Force | Out-Null
    }

    # Read current value (may not exist yet)
    $current = try {
        (Get-ItemProperty -Path $KeyPath -Name $Name -ErrorAction Stop).$Name
    } catch {
        $null
    }

    if ($current -eq $Value) {
        return $false   # Already correct – nothing to write
    }

    Set-ItemProperty -Path $KeyPath -Name $Name -Value $Value -Force
    return $true
}

<#
.SYNOPSIS
    Registers (or silently updates) a single Shell context menu entry.
    Returns a status string: 'created', 'updated', or 'unchanged'.
#>
function Register-ContextMenuEntry {
    param (
        [string]$RegistryPath,
        [string]$Label,
        [string]$Command,
        [string]$IconPath     # Path to EXE/ICO used as the menu icon
    )

    $commandPath = "$RegistryPath\command"
    $existed     = Test-Path $RegistryPath
    $changed     = $false

    # --- root key: display label + icon ---
    $changed = (Set-RegistryValue -KeyPath $RegistryPath -Name '(default)' -Value $Label) -or $changed
    $changed = (Set-RegistryValue -KeyPath $RegistryPath -Name 'Icon'      -Value $IconPath) -or $changed

    # --- command subkey ---
    $changed = (Set-RegistryValue -KeyPath $commandPath  -Name '(default)' -Value $Command) -or $changed

    if (-not $existed)   { return 'created' }
    if ($changed)        { return 'updated' }
    return 'unchanged'
}

# ---------------------------------------------------------------------------
# Uninstall mode
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Header '🗑️  Removing Windows Terminal context menu entries...'

    $regPaths = @(
        'HKCU:\Software\Classes\Directory\Background\shell\WindowsTerminal',
        'HKCU:\Software\Classes\Directory\shell\WindowsTerminal'
    )

    $removedAny = $false
    foreach ($path in $regPaths) {
        if (Test-Path $path) {
            try {
                Remove-Item -Path $path -Recurse -Force
                Write-Ok "Removed: $path"
                $removedAny = $true
            } catch {
                Write-Fail "Could not remove $path : $_"
                exit 1
            }
        } else {
            Write-Warn "Already absent: $path"
        }
    }

    Write-Host ''
    if ($removedAny) {
        Write-Header '✅ Uninstall complete. Right-click entries have been removed.'
    } else {
        Write-Header '✅ Nothing to remove – entries were not present.'
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Install mode
# ---------------------------------------------------------------------------

# --- 1. Locate wt.exe launcher (required) ---

Write-Header '🔍 Locating Windows Terminal...'

$wtLauncher = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"

if (-not (Test-Path $wtLauncher)) {
    Write-Fail "wt.exe launcher not found at:`n      $wtLauncher"
    Write-Step 'Make sure Windows Terminal is installed from the Microsoft Store,'
    Write-Step 'then try repairing it if the launcher is still missing.'
    exit 1
}

Write-Ok "Launcher : $wtLauncher"

# --- 2. Locate the icon source (best-effort; falls back to the launcher) ---
#
# WindowsApps is owned by TrustedInstaller, so a plain user account may get
# "Access Denied" when listing it. We suppress that error and fall back
# gracefully to wt.exe which also carries a usable icon.

$iconSource = $wtLauncher    # default fallback

$wtPackage = Get-ChildItem 'C:\Program Files\WindowsApps' `
                -Directory -Filter 'Microsoft.WindowsTerminal_*' `
                -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1

if ($wtPackage) {
    $candidate = Join-Path $wtPackage.FullName 'WindowsTerminal.exe'
    if (Test-Path $candidate) {
        $iconSource = $candidate
        Write-Ok "Icon     : $iconSource  (from package: $($wtPackage.Name))"
    } else {
        Write-Warn "Package found but WindowsTerminal.exe missing – using wt.exe as icon source."
    }
} else {
    Write-Warn "WindowsApps not enumerable (normal for standard accounts) – using wt.exe as icon source."
    Write-Ok "Icon     : $iconSource"
}

Write-Host ''

# --- 3. Build registry values ---

# The icon value for Shell registry entries is just the bare executable path
# (optionally followed by ,<index>, e.g. "C:\...\wt.exe,0").
# Do NOT wrap in quotes; the shell handles paths with spaces natively here.
$iconValue = $iconSource

# wt.exe accepts --startingDirectory with %V (the shell-expanded folder path)
# for both context-menu types.
$cmdBackground = "`"$wtLauncher`" --startingDirectory `"%V`""
$cmdFolder     = "`"$wtLauncher`" --startingDirectory `"%V`""

$label = 'Open in Windows Terminal Here'

# --- 4. Register entries ---

Write-Header '📝 Registering context menu entries...'

$entries = @(
    @{
        Path    = 'HKCU:\Software\Classes\Directory\Background\shell\WindowsTerminal'
        Label   = $label
        Command = $cmdBackground
        Desc    = 'Background right-click (inside a folder)'
    },
    @{
        Path    = 'HKCU:\Software\Classes\Directory\shell\WindowsTerminal'
        Label   = $label
        Command = $cmdFolder
        Desc    = 'Folder right-click (on a folder icon)'
    }
)

$anyError = $false

foreach ($entry in $entries) {
    try {
        $status = Register-ContextMenuEntry `
            -RegistryPath $entry.Path `
            -Label        $entry.Label `
            -Command      $entry.Command `
            -IconPath     $iconValue

        $tag = switch ($status) {
            'created'   { '✅ Created'   }
            'updated'   { '🔄 Updated'   }
            'unchanged' { '✔️  Unchanged' }
        }
        Write-Step "$tag — $($entry.Desc)"
    } catch {
        Write-Fail "Failed to register '$($entry.Desc)': $_"
        $anyError = $true
    }
}

Write-Host ''

if ($anyError) {
    Write-Header '⚠️  Installation completed with errors. Check the messages above.'
    exit 1
}

Write-Header '✅ Done! Right-click any folder or its background to open Windows Terminal there.'
Write-Step 'To remove these entries, run:'
Write-Step "   .\Install-WTContextMenu.ps1 -Uninstall"
exit 0
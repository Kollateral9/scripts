# ============================================================
# Add "Open in Windows Terminal Here" to the right-click menu
# Supports both background (empty area) and folder right-click
#
# Usage:
#   .\script.ps1            -> Install context menu entries
#   .\script.ps1 -Uninstall -> Remove context menu entries
# ============================================================

param (
    [switch]$Uninstall
)

# --- Uninstall mode ---
if ($Uninstall) {
    Write-Host "🗑️  Removing Windows Terminal context menu entries..."

    $paths = @(
        "HKCU:\Software\Classes\Directory\Background\shell\WindowsTerminal",
        "HKCU:\Software\Classes\Directory\shell\WindowsTerminal"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            Write-Host "   ✅ Removed: $path"
        } else {
            Write-Host "   ⚠️  Not found (already removed?): $path"
        }
    }

    Write-Host ""
    Write-Host "✅ Uninstall complete. Right-click entries have been removed."
    exit
}

# --- Find the latest Windows Terminal package ---
Write-Host "🔍 Looking for Windows Terminal installation..."

$wtPackage = Get-ChildItem "C:\Program Files\WindowsApps" -Directory -Filter "Microsoft.WindowsTerminal_*" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $wtPackage) {
    Write-Host "❌ Windows Terminal package not found in WindowsApps."
    Write-Host "   Make sure Windows Terminal is installed from the Microsoft Store."
    exit 1
}

Write-Host "   ✅ Found package: $($wtPackage.Name)"

# --- Resolve executable paths ---
$wtExePath = Join-Path $wtPackage.FullName "WindowsTerminal.exe"

if (-not (Test-Path $wtExePath)) {
    Write-Host "❌ WindowsTerminal.exe not found at expected path:"
    Write-Host "   $wtExePath"
    exit 1
}

$appPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"

if (-not (Test-Path $appPath)) {
    Write-Host "❌ wt.exe launcher not found at: $appPath"
    Write-Host "   Try repairing Windows Terminal from the Microsoft Store."
    exit 1
}

$iconPath = "`"$wtExePath`""

Write-Host "   ✅ Icon source : $wtExePath"
Write-Host "   ✅ Launcher    : $appPath"
Write-Host ""

# --- Helper: register a single context menu entry ---
function Register-ContextMenuEntry {
    param (
        [string]$RegistryPath,
        [string]$Label,
        [string]$Command
    )

    if (Test-Path $RegistryPath) {
        Write-Host "   ⚠️  Entry already exists, overwriting: $RegistryPath"
    }

    New-Item -Path $RegistryPath -Force |
        New-ItemProperty -Name "(default)" -Value $Label -Force |
        Out-Null

    Set-ItemProperty -Path $RegistryPath -Name "Icon" -Value $iconPath

    New-Item -Path "$RegistryPath\command" -Force |
        New-ItemProperty -Name "(default)" -Value $Command -Force |
        Out-Null
}

# --- Register context menu entries ---
Write-Host "📝 Registering context menu entries..."

# Right-click on empty background inside a folder
Register-ContextMenuEntry `
    -RegistryPath "HKCU:\Software\Classes\Directory\Background\shell\WindowsTerminal" `
    -Label "Open in Windows Terminal Here" `
    -Command "`"$appPath`" --startingDirectory ."

Write-Host "   ✅ Background right-click (inside folder)"

# Right-click on a folder itself
Register-ContextMenuEntry `
    -RegistryPath "HKCU:\Software\Classes\Directory\shell\WindowsTerminal" `
    -Label "Open in Windows Terminal Here" `
    -Command "`"$appPath`" --startingDirectory `"%V`""

Write-Host "   ✅ Folder right-click"

Write-Host ""
Write-Host "✅ Done! Right-click any folder or empty area to open Windows Terminal there."
Write-Host "   To remove these entries, run: .\script.ps1 -Uninstall"

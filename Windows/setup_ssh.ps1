# ─────────────────────────────────────────────────────────────────────────────
#  setup_ssh.ps1 — SSH key setup for GitHub (Windows)
#
#  Usage:
#    .\setup_ssh.ps1            -> Set up SSH key and configure Git
#    .\setup_ssh.ps1 -Uninstall -> Remove the generated SSH key and config
# ─────────────────────────────────────────────────────────────────────────────

param (
    [switch]$Uninstall
)

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Log   { param($msg) Write-Host "[✔] $msg" -ForegroundColor Green }
function Warn  { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Error { param($msg) Write-Host "[✘] $msg" -ForegroundColor Red; exit 1 }

# ── Check ssh-keygen is available ─────────────────────────────────────────────
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Error "ssh-keygen not found. Make sure OpenSSH is installed (Settings → Apps → Optional Features → OpenSSH Client)."
}

# ── Uninstall mode ────────────────────────────────────────────────────────────
if ($Uninstall) {
    Warn "Removing SSH key and Git global config..."

    $keyPath = "$env:USERPROFILE\.ssh\id_ed25519"
    foreach ($f in @($keyPath, "$keyPath.pub")) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            Log "Deleted: $f"
        } else {
            Warn "Not found (already removed?): $f"
        }
    }

    git config --global --unset user.name  2>$null
    git config --global --unset user.email 2>$null
    Log "Git global user.name and user.email cleared."
    Log "Uninstall complete."
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Helper — show public key, copy to clipboard, then verify GitHub connection
# ─────────────────────────────────────────────────────────────────────────────
function Show-KeyAndVerify {
    param ([string]$KeyPub)

    $border = "━" * 65
    Write-Host ""
    Write-Host $border -ForegroundColor Yellow
    Write-Host "  If you haven't already, add this key to GitHub:" -ForegroundColor Yellow
    Write-Host "  GitHub → Settings → SSH and GPG keys → New SSH key" -ForegroundColor Yellow
    Write-Host $border -ForegroundColor Yellow
    Write-Host ""
    Get-Content $KeyPub
    Write-Host ""
    Write-Host $border -ForegroundColor Yellow
    Write-Host ""

    # Copy to clipboard
    try {
        Get-Content $KeyPub | Set-Clipboard
        Log "Public key copied to clipboard."
    } catch {
        Warn "Could not copy to clipboard automatically — copy the key above manually."
    }

    Read-Host "Press ENTER after adding the key on GitHub"

    Log "Verifying connection to GitHub..."
    $result = & ssh -T git@github.com -o StrictHostKeyChecking=no 2>&1
    if ($result -match "successfully authenticated") {
        Log "GitHub connection successful! You're all set."
    } else {
        Warn "Verification done, but GitHub returned an unexpected message."
        Warn "Run manually to check: ssh -T git@github.com"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Helper — configure git user.name and user.email
# ─────────────────────────────────────────────────────────────────────────────
function Set-GitConfig {
    param (
        [string]$Email,
        [string]$Username
    )

    $currentName  = git config --global user.name  2>$null
    $currentEmail = git config --global user.email 2>$null

    if ($currentName -and $currentEmail) {
        Log "Git config already set: `"$currentName`" <$currentEmail>"
        $overwrite = Read-Host "Overwrite? [y/N]"
        if ($overwrite -notmatch "^[yY]$") {
            Log "Git config left unchanged."
            return
        }
    }

    git config --global user.name  $Username
    git config --global user.email $Email
    Log "Git configured: `"$Username`" <$Email>"
}

# ─────────────────────────────────────────────────────────────────────────────
#  1. Check for existing SSH key
# ─────────────────────────────────────────────────────────────────────────────
$sshDir      = "$env:USERPROFILE\.ssh"
$existingKey = Get-ChildItem -Path $sshDir -Filter "*.pub" -ErrorAction SilentlyContinue |
               Select-Object -First 1

if ($existingKey) {
    Log "Existing SSH key found: $($existingKey.FullName)"
    Warn "Checking whether it is already registered on GitHub..."

    $result = & ssh -T git@github.com -o StrictHostKeyChecking=no 2>&1
    if ($result -match "successfully authenticated") {
        Log "Key already registered on GitHub. Nothing to do."
    } else {
        Warn "Key does NOT appear to be registered on GitHub (or the connection failed)."
        Show-KeyAndVerify -KeyPub $existingKey.FullName
    }

    # Still offer to configure Git
    Write-Host ""
    $gitUsername = Read-Host "Enter your GitHub username (for git config)"
    $guessedEmail = (& ssh-keygen -lf $existingKey.FullName 2>$null) -replace ".*\s(\S+@\S+)\s.*", '$1'
    $gitEmailInput = Read-Host "Enter your GitHub email [$guessedEmail]"
    $gitEmail = if ($gitEmailInput) { $gitEmailInput } else { $guessedEmail }

    Set-GitConfig -Email $gitEmail -Username $gitUsername
    exit 0
}

Warn "No SSH key found. Starting setup..."

# ─────────────────────────────────────────────────────────────────────────────
#  2. Ask for email and username
# ─────────────────────────────────────────────────────────────────────────────
$email = Read-Host "Enter your GitHub email"
if (-not $email) { Error "Email not provided. Exiting." }

$gitUsername = Read-Host "Enter your GitHub username"
if (-not $gitUsername) { Error "Username not provided. Exiting." }

# ─────────────────────────────────────────────────────────────────────────────
#  3. Generate ed25519 key
# ─────────────────────────────────────────────────────────────────────────────
$keyPath = "$sshDir\id_ed25519"

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

Log "Generating ed25519 key at $keyPath ..."
& ssh-keygen -t ed25519 -C $email -f $keyPath -N '""'

if (-not (Test-Path "$keyPath.pub")) {
    Error "Key generation failed. Check the output above for details."
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. Start ssh-agent and add the key
# ─────────────────────────────────────────────────────────────────────────────
Log "Starting ssh-agent service..."
$agentStatus = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue

if ($agentStatus) {
    if ($agentStatus.StartType -eq "Disabled") {
        Set-Service -Name ssh-agent -StartupType Manual
        Log "ssh-agent startup type set to Manual."
    }
    if ($agentStatus.Status -ne "Running") {
        Start-Service ssh-agent
        Log "ssh-agent started."
    } else {
        Log "ssh-agent already running."
    }
} else {
    Warn "ssh-agent service not found — you may need to add the key manually later."
    Warn "Run: ssh-add $keyPath"
}

Log "Adding key to ssh-agent..."
& ssh-add $keyPath

# ─────────────────────────────────────────────────────────────────────────────
#  5. Show key, copy to clipboard, verify GitHub
# ─────────────────────────────────────────────────────────────────────────────
Show-KeyAndVerify -KeyPub "$keyPath.pub"

# ─────────────────────────────────────────────────────────────────────────────
#  6. Configure Git
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Set-GitConfig -Email $email -Username $gitUsername

Write-Host ""
Log "All done! Your SSH key is set up and Git is configured."
Log "To remove everything later, run: .\setup_ssh.ps1 -Uninstall"

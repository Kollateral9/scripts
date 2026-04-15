# =============================================================
#  setup-git-ssh.ps1 -- Universal SSH key setup for Git hosts
#
#  Usage examples:
#    .\setup-git-ssh.ps1                                      # Interactive: asks for the host
#    .\setup-git-ssh.ps1 -Host github.com                     # GitHub
#    .\setup-git-ssh.ps1 -ConfigOnly                          # Skips SSH, configures ONLY Git identity (folder/global)
#    .\setup-git-ssh.ps1 -RemoveAll                           # Deletes all SSH keys from the system
# =============================================================

param(
    [Alias("Host")]
    [string]$GitHost = "",

    [switch]$RemoveAll,
    [switch]$ConfigOnly
)

Set-StrictMode -Off

# ── Helpers ───────────────────────────────────────────────────
function log   { param($m) Write-Host " [OK] $m" -ForegroundColor Green }
function warn  { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function info  { param($m) Write-Host "  [i] $m" -ForegroundColor Cyan }
function err   { param($m) Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }
function rule  { Write-Host ("=" * 65) -ForegroundColor DarkGray }
function blank { Write-Host "" }

# ── Detect provider from hostname ─────────────────────────────
function Get-GitProvider {
    param([string]$hostname)
    if ($hostname -match "github\.com")    { return "GitHub" }
    if ($hostname -match "bitbucket\.org") { return "Bitbucket" }
    if ($hostname -match "gitlab\.")       { return "GitLab" }
    # Generic self-hosted: assuming it's GitLab or Gitea
    return "Git"
}

function Get-SshKeysUrl {
    param([string]$hostname, [string]$provider)
    switch ($provider) {
        "GitHub"    { return "https://$hostname/settings/keys" }
        "Bitbucket" { return "https://$hostname/account/settings/ssh-keys/" }
        "GitLab"    { return "https://$hostname/-/user_settings/ssh_keys" }
        default     { return "https://$hostname" }
    }
}

function Get-TestUser {
    param([string]$provider)
    switch ($provider) {
        "Bitbucket" { return "bitbucket" }
        default     { return "git" }
    }
}

function Get-WelcomePattern {
    param([string]$provider)
    switch ($provider) {
        "GitHub"    { return "successfully authenticated" }
        "Bitbucket" { return "logged in as" }
        "GitLab"    { return "Welcome to GitLab" }
        default     { return "." }   # any output = connected
    }
}

# ── Banner ────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  Universal Git SSH Setup" -ForegroundColor Cyan
Write-Host "  PowerShell Edition" -ForegroundColor DarkGray
rule
blank

# ── Check prerequisites ───────────────────────────────────────
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    warn "ssh-keygen not found. Installing OpenSSH Client..."
    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        err "Failed to install OpenSSH. Go to Settings > Apps > Optional features."
    }
}
log "OpenSSH found."

# ── Ensure .ssh directory exists ──────────────────────────────
$SshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
}

# ── Function: start ssh-agent ─────────────────────────────────
function Start-SshAgent {
    $svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.StartType -eq "Disabled") { Set-Service ssh-agent -StartupType Manual }
        if ($svc.Status -ne "Running")     { Start-Service ssh-agent }
        log "ssh-agent is running."
    } else {
        warn "ssh-agent service not available (common on Windows Home)."
    }
}

# ── REMOVE ALL LOGIC ──────────────────────────────────────────
if ($RemoveAll) {
    blank
    warn "WARNING: You are about to delete ALL SSH keys in $SshDir!"
    warn "This action cannot be undone and will break existing SSH connections."
    $confirm = Read-Host "  Are you absolutely sure? [y/N]"
    
    if ($confirm -match "^[yY]$") {
        blank
        log "Clearing keys from ssh-agent..."
        Start-SshAgent
        & ssh-add -D 2>$null

        log "Deleting key files..."
        $pubKeys = Get-ChildItem -Path $SshDir -Filter "*.pub" -ErrorAction SilentlyContinue
        $count = 0

        foreach ($pub in $pubKeys) {
            $privPath = $pub.FullName -replace "\.pub$", ""
            
            # Remove Public Key
            Remove-Item -Path $pub.FullName -Force -ErrorAction SilentlyContinue
            
            # Remove matching Private Key
            if (Test-Path $privPath) {
                Remove-Item -Path $privPath -Force -ErrorAction SilentlyContinue
            }
            $count++
        }

        log "Successfully deleted $count key pair(s)."
        blank
        rule
        Write-Host "  Cleanup completed. Exiting." -ForegroundColor Green
        rule
        blank
        exit 0
    } else {
        blank
        log "Operation cancelled. No keys were deleted. Exiting."
        exit 0
    }
}

# ── Function: show key, copy, wait for confirmation ───────────
function Show-KeyAndWait {
    param([string]$TargetPubKeyPath)

    $pubKey = (Get-Content $TargetPubKeyPath -Raw).Trim()

    blank
    rule
    Write-Host "  Add this key to ${Provider}:" -ForegroundColor Yellow
    Write-Host "  $KeysUrl" -ForegroundColor Yellow
    rule
    blank
    Write-Host $pubKey -ForegroundColor White
    blank
    rule

    try {
        $pubKey | Set-Clipboard
        log "Key copied to clipboard."
    } catch {
        warn "Failed to copy to clipboard. Please copy the text above manually."
    }

    blank
    Read-Host "  Press ENTER after adding the key to ${Provider}..."
}

# ── Function: test connection ─────────────────────────────────
function Test-SshConnection {
    log "Testing connection to $GitHost..."
    $result = & ssh -T "${TestUser}@${GitHost}" -o StrictHostKeyChecking=accept-new 2>&1
    if ($result -match $WelcomePat) {
        log "Connection to $GitHost successful!"
        return $true
    } else {
        warn "Connection completed but non-standard response. Output:"
        Write-Host "    $result" -ForegroundColor DarkGray
        warn "Test manually: ssh -T ${TestUser}@${GitHost}"
        return $false
    }
}

# ── Function: configure git user (Global or Folder specific) ──
function Setup-GitConfig {
    param([string]$Email, [string]$Username, [string]$SafeName)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        warn "git non found in PATH. Skipping git config."
        return
    }

    blank
    info "Git Identity Configuration"
    info "You can set this identity Globally (for the whole PC)"
    info "or tie it to a Specific Folder (e.g. C:\Projects\Work\)"
    $Workspace = Read-Host "  Enter the folder path (leave empty for Global)"

    if (-not $Workspace) {
        # Standard Global Configuration
        git config --global user.name  $Username
        git config --global user.email $Email
        log "Git configured GLOBALLY: `"$Username`" <$Email>"
    } else {
        # Folder-based Configuration (IncludeIf)
        if (-not (Test-Path $Workspace)) {
            warn "Folder '$Workspace' does not exist. Creating it..."
            New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
        }

        # Git requires forward slashes (/) and a trailing slash for directories
        $GitPath = $Workspace -replace "\\", "/"
        if (-not $GitPath.EndsWith("/")) { $GitPath += "/" }

        # Create the specific config file
        $SpecificConfigName = ".gitconfig-$SafeName"
        $SpecificConfigPath = Join-Path $Workspace $SpecificConfigName
        $GitSpecificPath = $SpecificConfigPath -replace "\\", "/"

        $block = @"
[user]
    name = $Username
    email = $Email
"@
        Set-Content -Path $SpecificConfigPath -Value $block
        log "Specific config file created: $SpecificConfigPath"

        # Register the rule in the global .gitconfig
        git config --global "includeIf.gitdir:${GitPath}.path" "`"$GitSpecificPath`""
        log "'includeIf' rule activated for folder: $Workspace"
    }
}

# ── Function: update ~/.ssh/config ────────────────────────────
function Update-SshConfig {
    param([string]$KeyFilePath)

    $ConfigPath = Join-Path $SshDir "config"
    $block = @"

Host $GitHost
    HostName $GitHost
    User $TestUser
    IdentityFile $KeyFilePath
    IdentitiesOnly yes
    AddKeysToAgent yes
"@

    if (Test-Path $ConfigPath) {
        $existing = Get-Content $ConfigPath -Raw
        if ($existing -match [regex]::Escape("Host $GitHost")) {
            warn "Host block '$GitHost' already exists in ~/.ssh/config. Skipping."
            return
        }
    }

    Add-Content -Path $ConfigPath -Value $block
    log "Host block added to ~/.ssh/config."
}

# ── CONFIG ONLY LOGIC ─────────────────────────────────────────
if ($ConfigOnly) {
    blank
    info "Git Identity Configuration Mode (Skipping SSH Setup)"
    $email = Read-Host "  Enter your email"
    if (-not $email) { err "Email not provided. Exiting." }

    $gitUsername = Read-Host "  Enter your Git username"
    if (-not $gitUsername) { err "Username not provided. Exiting." }

    $profileName = Read-Host "  Profile name (e.g. work, personal) [default: custom]"
    if (-not $profileName) { $profileName = "custom" }

    Setup-GitConfig -Email $email -Username $gitUsername -SafeName $profileName
    
    blank
    rule
    Write-Host "  Identity setup completed. Exiting." -ForegroundColor Green
    rule
    blank
    exit 0
}

# =============================================================
#  MAIN LOGIC
# =============================================================

# ── 1. Check existing keys BEFORE asking for host ─────────────
$existingKeys = @(Get-ChildItem -Path $SshDir -Filter "*.pub" -ErrorAction SilentlyContinue)
$GenerateNew = $true
$SelectedPubPath = $null
$SelectedKeyPath = $null

if ($existingKeys.Count -gt 0) {
    blank
    info "Existing SSH keys found in ~/.ssh/:"
    for ($i = 0; $i -lt $existingKeys.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $existingKeys[$i].Name) -ForegroundColor White
    }
    Write-Host "  [0] Create a NEW key" -ForegroundColor Green
    blank

    $choice = Read-Host "  Select an option [0-$($existingKeys.Count)]"
    
    if ($choice -match '^[1-9][0-9]*$' -and [int]$choice -le $existingKeys.Count) {
        $GenerateNew = $false
        $SelectedPubPath = $existingKeys[[int]$choice - 1].FullName
        $SelectedKeyPath = $SelectedPubPath -replace "\.pub$", ""
        
        log "Selected existing key: $($existingKeys[[int]$choice - 1].Name)"
        
        # Read and copy key
        $pubKeyContent = (Get-Content $SelectedPubPath -Raw).Trim()
        blank
        rule
        Write-Host "  Key Content:" -ForegroundColor Yellow
        rule
        Write-Host $pubKeyContent -ForegroundColor White
        rule
        try {
            $pubKeyContent | Set-Clipboard
            log "Key copied to clipboard!"
        } catch {
            warn "Failed to copy to clipboard. Please copy manually."
        }
        blank
        
        $continue = Read-Host "  Do you want to proceed and configure a Git Host with this key? [Y/n]"
        if ($continue -match "^[nN]$") {
            log "Exiting as requested."
            exit 0
        }
    } elseif ($choice -eq "0") {
        log "Will create a new SSH key."
    } else {
        err "Invalid selection. Exiting."
    }
}

# ── 2. Prompt for host if not passed as parameter ─────────────
if (-not $GitHost) {
    blank
    info "Examples: github.com  |  gitlab.com  |  gitlab.eggtronic.it  |  bitbucket.org"
    $GitHost = Read-Host "  Enter the Git host"
    if (-not $GitHost) { err "Host not provided. Exiting." }
}

$Provider   = Get-GitProvider -hostname $GitHost
$KeysUrl    = Get-SshKeysUrl  -hostname $GitHost -provider $Provider
$TestUser   = Get-TestUser    -provider $Provider
$WelcomePat = Get-WelcomePattern -provider $Provider

blank
log "Host:     $GitHost"
log "Provider: $Provider"
rule

# ── Setup Variables ───────────────────────────────────────────
$SafeName = $GitHost -replace "[^a-zA-Z0-9]", "_"   # e.g., gitlab_eggtronic_it

if ($GenerateNew) {
    $KeyPath = Join-Path $SshDir "id_ed25519_$SafeName"
    $PubPath = "$KeyPath.pub"
} else {
    $KeyPath = $SelectedKeyPath
    $PubPath = $SelectedPubPath
}

if ($GenerateNew) {

    # ── A. Generate new key ───────────────────────────────────
    blank
    $email = Read-Host "  Enter your email"
    if (-not $email) { err "Email not provided. Exiting." }

    $gitUsername = Read-Host "  Enter your Git username (name shown on Git commits)"
    if (-not $gitUsername) { err "Username not provided. Exiting." }

    blank
    log "Generating key: $KeyPath"
    & ssh-keygen -t ed25519 -C $email -f $KeyPath -N '""'
    if ($LASTEXITCODE -ne 0) { err "Key generation failed." }

    Start-SshAgent
    & ssh-add $KeyPath
    if ($LASTEXITCODE -eq 0) { log "Key added to the agent." }

    Update-SshConfig -KeyFilePath $KeyPath
    Show-KeyAndWait  -TargetPubKeyPath $PubPath
    Test-SshConnection | Out-Null
    
    Setup-GitConfig -Email $email -Username $gitUsername -SafeName $SafeName

} else {

    # ── B. Use existing selected key ──────────────────────────
    Start-SshAgent
    & ssh-add $KeyPath 2>$null

    Update-SshConfig -KeyFilePath $KeyPath

    $connected = Test-SshConnection
    if (-not $connected) {
        # If it fails, maybe it hasn't been added to the Git server yet
        Show-KeyAndWait -TargetPubKeyPath $PubPath
        Test-SshConnection | Out-Null
    }

    blank
    $gitUsername = Read-Host "  Git username for $Provider (for git config)"
    $keyComment  = (& ssh-keygen -lf $PubPath 2>$null) -split " " | Select-Object -Index 2
    $defaultEmail = if ($keyComment) { $keyComment } else { "" }
    $gitEmail = Read-Host "  Email [$defaultEmail]"
    if (-not $gitEmail) { $gitEmail = $defaultEmail }
    
    Setup-GitConfig -Email $gitEmail -Username $gitUsername -SafeName $SafeName
}

blank
rule
Write-Host "  Setup completed for $GitHost" -ForegroundColor Green
rule
blank
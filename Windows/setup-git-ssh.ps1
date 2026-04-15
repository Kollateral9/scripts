# =============================================================
#  setup-git-ssh.ps1 -- Universal SSH key setup for Git hosts
#
#  Esempi di utilizzo:
#    .\setup-git-ssh.ps1                                      # Interattivo: chiede l'host
#    .\setup-git-ssh.ps1 -Host github.com                     # GitHub
#    .\setup-git-ssh.ps1 -Host gitlab.com                     # GitLab pubblico
#    .\setup-git-ssh.ps1 -Host gitlab.eggtronic.it            # GitLab self-hosted
#    .\setup-git-ssh.ps1 -Host bitbucket.org                  # Bitbucket
# =============================================================

param(
    [Alias("Host")]
    [string]$GitHost = ""
)

Set-StrictMode -Off

# ── Helpers ───────────────────────────────────────────────────
function log   { param($m) Write-Host " [OK] $m" -ForegroundColor Green }
function warn  { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }
function info  { param($m) Write-Host "  [i] $m" -ForegroundColor Cyan }
function err   { param($m) Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }
function rule  { Write-Host ("=" * 65) -ForegroundColor DarkGray }
function blank { Write-Host "" }

# ── Rileva il provider dal hostname ───────────────────────────
function Get-GitProvider {
    param([string]$hostname)
    if ($hostname -match "github\.com")    { return "GitHub" }
    if ($hostname -match "bitbucket\.org") { return "Bitbucket" }
    if ($hostname -match "gitlab\.")       { return "GitLab" }
    # Self-hosted generico: proviamo a capire se e' GitLab o Gitea
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
        default     { return "." }   # qualsiasi output = connesso
    }
}

# ── Banner ────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  Universal Git SSH Setup" -ForegroundColor Cyan
Write-Host "  PowerShell Edition" -ForegroundColor DarkGray
rule
blank

# ── Verifica prerequisiti ─────────────────────────────────────
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    warn "ssh-keygen non trovato. Installo OpenSSH Client..."
    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        err "Impossibile installare OpenSSH. Vai su Impostazioni > App > Funzionalita' opzionali."
    }
}
log "OpenSSH trovato."

# ── Chiedi l'host se non passato da parametro ─────────────────
if (-not $GitHost) {
    blank
    info "Esempi: github.com  |  gitlab.com  |  gitlab.eggtronic.it  |  bitbucket.org"
    $GitHost = Read-Host "  Inserisci il Git host"
    if (-not $GitHost) { err "Host non fornito. Uscita." }
}

$Provider   = Get-GitProvider -hostname $GitHost
$KeysUrl    = Get-SshKeysUrl  -hostname $GitHost -provider $Provider
$TestUser   = Get-TestUser    -provider $Provider
$WelcomePat = Get-WelcomePattern -provider $Provider

blank
log "Host:     $GitHost"
log "Provider: $Provider"
rule

# ── Percorsi ──────────────────────────────────────────────────
$SshDir   = Join-Path $env:USERPROFILE ".ssh"
$SafeName = $GitHost -replace "[^a-zA-Z0-9]", "_"   # es. gitlab_eggtronic_it
$KeyName  = "id_ed25519_$SafeName"
$KeyPath  = Join-Path $SshDir $KeyName
$PubPath  = "$KeyPath.pub"

if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
}

# ── Funzione: avvia ssh-agent ─────────────────────────────────
function Start-SshAgent {
    $svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.StartType -eq "Disabled") { Set-Service ssh-agent -StartupType Manual }
        if ($svc.Status -ne "Running")     { Start-Service ssh-agent }
        log "ssh-agent attivo."
    } else {
        warn "Servizio ssh-agent non disponibile (comune su Windows Home)."
    }
}

# ── Funzione: mostra chiave, copia, attendi conferma ──────────
function Show-KeyAndWait {
    param([string]$PubKeyPath)

    $pubKey = (Get-Content $PubKeyPath -Raw).Trim()

    blank
    rule
    Write-Host "  Aggiungi questa chiave su ${Provider}:" -ForegroundColor Yellow
    Write-Host "  $KeysUrl" -ForegroundColor Yellow
    rule
    blank
    Write-Host $pubKey -ForegroundColor White
    blank
    rule

    try {
        $pubKey | Set-Clipboard
        log "Chiave copiata negli appunti."
    } catch {
        warn "Impossibile copiare negli appunti. Copia manualmente il testo sopra."
    }

    blank
    Read-Host "  Premi INVIO dopo aver aggiunto la chiave su ${Provider}..."
}

# ── Funzione: testa la connessione ────────────────────────────
function Test-SshConnection {
    log "Verifica connessione a $GitHost..."
    $result = & ssh -T "${TestUser}@${Host}" -o StrictHostKeyChecking=accept-new 2>&1
    if ($result -match $WelcomePat) {
        log "Connessione a $GitHost riuscita!"
        return $true
    } else {
        warn "Connessione completata ma risposta non standard. Output:"
        Write-Host "    $result" -ForegroundColor DarkGray
        warn "Prova manualmente: ssh -T ${TestUser}@${Host}"
        return $false
    }
}

# ── Funzione: configura git user ──────────────────────────────
function Setup-GitConfig {
    param([string]$Email, [string]$Username)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        warn "git non trovato nel PATH. Salto la configurazione git."
        return
    }

    $currentName  = git config --global user.name  2>$null
    $currentEmail = git config --global user.email 2>$null

    if ($currentName -and $currentEmail) {
        log "Git gia' configurato: `"$currentName`" <$currentEmail>"
        $overwrite = Read-Host "  Vuoi sovrascriverla? [s/N]"
        if ($overwrite -notmatch "^[sS]$") {
            log "Configurazione Git invariata."
            return
        }
    }

    git config --global user.name  $Username
    git config --global user.email $Email
    log "Git configurato: `"$Username`" <$Email>"
}

# ── Funzione: aggiorna ~/.ssh/config ──────────────────────────
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
            warn "Blocco Host '$GitHost' gia' presente in ~/.ssh/config. Salto."
            return
        }
    }

    Add-Content -Path $ConfigPath -Value $block
    log "Blocco Host aggiunto a ~/.ssh/config."
}

# =============================================================
#  MAIN
# =============================================================

# ── 1. Controlla chiavi esistenti per questo host ─────────────
blank
$existingPub = if (Test-Path $PubPath) { $PubPath } else { $null }

# Cerca anche eventuali altre chiavi .pub nella cartella
if (-not $existingPub) {
    $existingPub = Get-ChildItem -Path $SshDir -Filter "*.pub" -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
    if ($existingPub) {
        warn "Nessuna chiave specifica per '$GitHost' trovata."
        warn "Chiave esistente: $existingPub"
        $use = Read-Host "  Usare questa chiave esistente invece di crearne una nuova? [s/N]"
        if ($use -notmatch "^[sS]$") { $existingPub = $null }
    }
}

if ($existingPub) {
    log "Uso chiave: $existingPub"
    $fp = (& ssh-keygen -lf $existingPub 2>$null) -split " " | Select-Object -Index 1

    Start-SshAgent
    & ssh-add ($existingPub -replace "\.pub$", "") 2>$null

    Update-SshConfig -KeyFilePath ($existingPub -replace "\.pub$", "")

    $connected = Test-SshConnection
    if (-not $connected) {
        Show-KeyAndWait -PubKeyPath $existingPub
        Test-SshConnection | Out-Null
    }

    blank
    $gitUsername = Read-Host "  Nome utente $Provider (per git config)"
    $keyComment  = (& ssh-keygen -lf $existingPub 2>$null) -split " " | Select-Object -Index 2
    $defaultEmail = if ($keyComment) { $keyComment } else { "" }
    $gitEmail = Read-Host "  Email [$defaultEmail]"
    if (-not $gitEmail) { $gitEmail = $defaultEmail }
    Setup-GitConfig -Email $gitEmail -Username $gitUsername

} else {

    # ── 2. Nessuna chiave: chiedi credenziali ─────────────────
    blank
    $email = Read-Host "  Inserisci la tua email"
    if (-not $email) { err "Email non fornita. Uscita." }

    $gitUsername = Read-Host "  Inserisci il tuo nome utente Git (nome che viene mostrato su Git a ogni commit)"
    if (-not $gitUsername) { err "Nome utente non fornito. Uscita." }

    # ── 3. Genera chiave ed25519 ──────────────────────────────
    blank
    log "Generazione chiave: $KeyPath"
    & ssh-keygen -t ed25519 -C $email -f $KeyPath -N '""'
    if ($LASTEXITCODE -ne 0) { err "Generazione chiave fallita." }

    # ── 4. Avvia agente e aggiungi chiave ─────────────────────
    Start-SshAgent
    & ssh-add $KeyPath
    if ($LASTEXITCODE -eq 0) { log "Chiave aggiunta all'agente." }

    # ── 5. Aggiorna config ────────────────────────────────────
    Update-SshConfig -KeyFilePath $KeyPath

    # ── 6. Mostra chiave e attendi registrazione ──────────────
    Show-KeyAndWait -PubKeyPath $PubPath

    # ── 7. Testa connessione ──────────────────────────────────
    Test-SshConnection | Out-Null

    # ── 8. Configura git ──────────────────────────────────────
    blank
    Setup-GitConfig -Email $email -Username $gitUsername
}

blank
rule
Write-Host "  Setup completato per $GitHost" -ForegroundColor Green
rule
blank

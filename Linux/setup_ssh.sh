#!/bin/bash

# ─────────────────────────────────────────────
#  setup_ssh.sh — SSH key setup for GitHub
# ─────────────────────────────────────────────

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }

# ── Mostra chiave, copia negli appunti, verifica GitHub ───────────────────────
show_key_and_verify() {
    local key_pub="$1"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Se non l'hai ancora fatto, aggiungi questa chiave a GitHub:${NC}"
    echo -e "${YELLOW}  GitHub → Settings → SSH and GPG keys → New SSH key${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    cat "$key_pub"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if command -v xclip &>/dev/null; then
        cat "$key_pub" | xclip -selection clipboard
        log "Chiave copiata negli appunti con xclip."
    elif command -v xsel &>/dev/null; then
        cat "$key_pub" | xsel --clipboard --input
        log "Chiave copiata negli appunti con xsel."
    else
        warn "xclip/xsel non trovati — copia la chiave manualmente dal testo sopra."
    fi

    echo ""
    read -rp "Premi INVIO dopo aver aggiunto la chiave su GitHub..."

    log "Verifica connessione a GitHub..."
    if ssh -T git@github.com -o StrictHostKeyChecking=no 2>&1 | grep -q "successfully authenticated"; then
        log "Connessione a GitHub riuscita! Tutto pronto."
    else
        warn "Verifica completata, ma GitHub ha restituito un messaggio non standard."
        warn "Esegui manualmente: ssh -T git@github.com"
    fi
}

# ── Configura git user.name e user.email ──────────────────────────────────────
setup_git_config() {
    local email="$1"
    local username="$2"

    CURRENT_NAME=$(git config --global user.name 2>/dev/null || true)
    CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || true)

    if [ -n "$CURRENT_NAME" ] && [ -n "$CURRENT_EMAIL" ]; then
        log "Configurazione Git già presente: \"$CURRENT_NAME\" <$CURRENT_EMAIL>"
        read -rp "Vuoi sovrascriverla? [s/N] " OVERWRITE
        if [[ ! "$OVERWRITE" =~ ^[sS]$ ]]; then
            log "Configurazione Git invariata."
            return
        fi
    fi

    git config --global user.name "$username"
    git config --global user.email "$email"
    log "Git configurato: \"$username\" <$email>"
}

# ── 1. Controlla se esiste già una chiave SSH ──────────────────────────────────
EXISTING_KEY=$(find ~/.ssh -maxdepth 1 -name "*.pub" 2>/dev/null | head -n 1)

if [ -n "$EXISTING_KEY" ]; then
    log "Chiave SSH già presente: $EXISTING_KEY"
    warn "Verifica se è già registrata su GitHub..."

    if ssh -T git@github.com -o StrictHostKeyChecking=no 2>&1 | grep -q "successfully authenticated"; then
        log "Chiave già registrata su GitHub. Tutto ok."
    else
        warn "La chiave NON risulta registrata su GitHub (o la connessione è fallita)."
        show_key_and_verify "$EXISTING_KEY"
    fi

    # Configura git anche se la chiave era già presente
    echo ""
    read -rp "Inserisci il tuo nome utente GitHub (per git config): " GIT_USERNAME
    EXISTING_EMAIL=$(ssh-keygen -lf "$EXISTING_KEY" 2>/dev/null | awk '{print $3}')
    read -rp "Inserisci la tua email GitHub [$EXISTING_EMAIL]: " GIT_EMAIL
    GIT_EMAIL="${GIT_EMAIL:-$EXISTING_EMAIL}"
    setup_git_config "$GIT_EMAIL" "$GIT_USERNAME"
    exit 0
fi

warn "Nessuna chiave SSH trovata. Avvio configurazione..."

# ── 2. Richiedi email e nome utente ───────────────────────────────────────────
read -rp "Inserisci la tua email GitHub: " EMAIL
if [ -z "$EMAIL" ]; then
    error "Email non fornita. Uscita."
fi

read -rp "Inserisci il tuo nome utente GitHub: " GIT_USERNAME
if [ -z "$GIT_USERNAME" ]; then
    error "Nome utente non fornito. Uscita."
fi

# ── 3. Genera la chiave ed25519 ────────────────────────────────────────────────
KEY_PATH="$HOME/.ssh/id_ed25519"

log "Generazione chiave ed25519 in $KEY_PATH..."
ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""

# ── 4. Avvia ssh-agent e aggiungi la chiave ────────────────────────────────────
log "Avvio ssh-agent..."
eval "$(ssh-agent -s)" > /dev/null

log "Aggiunta chiave all'agente..."
ssh-add "$KEY_PATH"

# ── 5. Mostra chiave, copia negli appunti, verifica GitHub ────────────────────
show_key_and_verify "${KEY_PATH}.pub"

# ── 6. Configura git ──────────────────────────────────────────────────────────
echo ""
setup_git_config "$EMAIL" "$GIT_USERNAME"

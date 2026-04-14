#!/bin/bash

# ─────────────────────────────────────────────────────────────
#  setup_dev.sh — Dev machine setup for Ubuntu/Debian
# ─────────────────────────────────────────────────────────────

set -eo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

# ── --check mode ──────────────────────────────────────────────────────────────
CHECK_MODE=false
if [[ "${1:-}" == "--check" ]]; then
    CHECK_MODE=true
fi

if $CHECK_MODE; then
    echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  setup_dev.sh --check   (read-only status report)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME=$(eval echo "~$REAL_USER")

    check_cmd() {
        local label="$1" cmd="$2"
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver=$("$cmd" --version 2>/dev/null | head -1) || ver="installed"
            log "$label: $ver"
        else
            warn "$label: not installed"
        fi
    }

    check_dir() {
        local label="$1" dir="$2"
        if [ -d "$dir" ]; then
            log "$label: found ($dir)"
        else
            warn "$label: not found"
        fi
    }

    check_alias() {
        local label="$1" pattern="$2"
        if grep -q "$pattern" "$REAL_HOME/.bashrc" 2>/dev/null; then
            log "$label: configured in .bashrc"
        else
            warn "$label: missing from .bashrc"
        fi
    }

    section "System tools"
    for tool in curl wget git xclip htop jq tmux; do
        check_cmd "$tool" "$tool"
    done

    section "Modern CLI tools"
    check_cmd "bat (batcat)" "batcat"
    check_cmd "ripgrep (rg)" "rg"
    check_cmd "fzf" "fzf"
    check_cmd "eza" "eza"

    section "Applications"
    check_cmd "Google Chrome" "google-chrome"
    check_cmd "Visual Studio Code" "code"
    check_cmd "GitHub CLI" "gh"
    check_cmd "DBeaver" "dbeaver"
    check_cmd "Beekeeper Studio" "beekeeper-studio"

    section "Languages & runtimes"
    check_cmd "Python 3" "python3"
    check_cmd "pip3" "pip3"
    check_dir "pyenv" "$REAL_HOME/.pyenv"
    check_dir "nvm" "$REAL_HOME/.nvm"

    if [ -d "$REAL_HOME/.nvm" ]; then
        NODE_VER=$(sudo -u "$REAL_USER" bash -c \
            'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && node --version 2>/dev/null' || true)
        if [ -n "$NODE_VER" ]; then
            log "Node.js (via nvm): $NODE_VER"
        else
            warn "Node.js: nvm found but no Node version active"
        fi
    fi

    section "Docker"
    check_cmd "Docker" "docker"
    if command -v docker &>/dev/null; then
        COMPOSE_VER=$(docker compose version 2>/dev/null | head -1) || true
        if [ -n "$COMPOSE_VER" ]; then
            log "Docker Compose: $COMPOSE_VER"
        else
            warn "Docker Compose: not available"
        fi
        if groups "$REAL_USER" 2>/dev/null | grep -q docker; then
            log "User '$REAL_USER' is in the docker group"
        else
            warn "User '$REAL_USER' is NOT in the docker group"
        fi
    fi

    section "Flatpak"
    check_cmd "Flatpak" "flatpak"
    if command -v flatpak &>/dev/null && flatpak remotes 2>/dev/null | grep -q flathub; then
        log "Flathub remote: configured"
    else
        warn "Flathub remote: not configured"
    fi

    section "Shell config (.bashrc)"
    check_alias "alias 'update'" "alias update="
    check_alias "alias 'bat'" "alias bat="
    check_alias "alias 'ls' (eza)" "alias ls="
    check_alias "pyenv init" "pyenv init"
    check_alias "NVM_DIR" "NVM_DIR"

    section "Git config"
    GIT_NAME=$(sudo -u "$REAL_USER" git config --global user.name 2>/dev/null || true)
    GIT_EMAIL=$(sudo -u "$REAL_USER" git config --global user.email 2>/dev/null || true)
    if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
        log "Git: \"$GIT_NAME\" <$GIT_EMAIL>"
    else
        warn "Git: user.name or user.email not set"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  Check complete. Run without --check to install/update.${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
fi

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "Run this script with sudo: sudo bash setup_dev.sh"
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ── Detect distro ─────────────────────────────────────────────────────────────
source /etc/os-release
DISTRO_ID="${ID}"
DISTRO_CODENAME="${VERSION_CODENAME}"

if [[ "$DISTRO_ID" != "ubuntu" && "$DISTRO_ID" != "debian" ]]; then
    error "Unsupported distro: $DISTRO_ID. This script supports Ubuntu and Debian only."
fi

log "Detected distro: $DISTRO_ID ($DISTRO_CODENAME)"

append_bashrc() {
    echo "$1" >> "$REAL_HOME/.bashrc"
}

# ── 1. System update ──────────────────────────────────────────────────────────
section "System update"
apt update && apt upgrade -y && apt autoremove -y && apt autoclean
log "System updated."

UPDATE_ALIAS="alias update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y && sudo apt autoclean && flatpak update -y'"
if ! grep -q "alias update=" "$REAL_HOME/.bashrc" 2>/dev/null; then
    append_bashrc ""
    append_bashrc "# System update alias"
    append_bashrc "$UPDATE_ALIAS"
    log "Alias 'update' added to ~/.bashrc."
else
    warn "Alias 'update' already in ~/.bashrc, skipped."
fi

# ── 2. Base dependencies ─────────────────────────────────────────────────────
section "Base dependencies"
apt install -y \
    curl wget git xclip htop jq tmux \
    bat ripgrep fzf \
    build-essential ca-certificates gnupg \
    software-properties-common apt-transport-https \
    flatpak
log "Base dependencies installed."

if ! flatpak remotes | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    log "Flathub repository added."
else
    warn "Flathub already configured."
fi

if ! grep -q "alias bat=" "$REAL_HOME/.bashrc" 2>/dev/null; then
    append_bashrc ""
    append_bashrc "# bat (installed as batcat on Ubuntu/Debian)"
    append_bashrc "alias bat='batcat'"
    log "Alias 'bat' -> 'batcat' added to ~/.bashrc."
fi

# ── 3. eza ────────────────────────────────────────────────────────────────────
section "eza (modern ls)"
if ! command -v eza &>/dev/null; then
    EZA_URL=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest \
        | jq -r '.assets[] | select(.name | endswith("_amd64.deb")) | .browser_download_url')

    if [ -z "$EZA_URL" ] || [ "$EZA_URL" = "null" ]; then
        warn "Could not fetch eza URL from GitHub API (rate limit?). Skipped."
    else
        wget -qO /tmp/eza.deb "$EZA_URL"
        apt install -y /tmp/eza.deb
        rm -f /tmp/eza.deb
        log "eza installed."
    fi
else
    warn "eza already installed, skipped."
fi

if ! grep -q "alias ls=" "$REAL_HOME/.bashrc" 2>/dev/null; then
    append_bashrc ""
    append_bashrc "# eza as ls replacement"
    append_bashrc "alias ls='eza --icons'"
    append_bashrc "alias ll='eza --icons -lah'"
    append_bashrc "alias tree='eza --icons --tree'"
    log "Aliases ls/ll/tree -> eza added to ~/.bashrc."
fi

# ── 4. Google Chrome ──────────────────────────────────────────────────────────
section "Google Chrome"
if ! command -v google-chrome &>/dev/null; then
    wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt install -y /tmp/chrome.deb
    rm -f /tmp/chrome.deb
    log "Chrome installed."
else
    warn "Chrome already installed, skipped."
fi

sudo -u "$REAL_USER" xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null \
    && log "Chrome set as default browser." \
    || warn "Could not set default browser (may require an active desktop session)."

# ── 5. Visual Studio Code ─────────────────────────────────────────────────────
section "Visual Studio Code"
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
apt update -qq
apt install -y code
log "VSCode installed/updated."

# ── 6. GitHub CLI (gh) ────────────────────────────────────────────────────────
section "GitHub CLI"
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
apt update -qq
apt install -y gh
log "GitHub CLI installed/updated."

# ── 7. Python (venv + pip + pyenv) ───────────────────────────────────────────
section "Python — venv + pip"
apt install -y python3-venv python3-pip python3-dev
log "python3-venv and pip installed."

section "pyenv"
apt install -y \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

PYENV_DIR="$REAL_HOME/.pyenv"
if [ ! -d "$PYENV_DIR" ]; then
    sudo -u "$REAL_USER" bash -c 'curl -fsSL https://pyenv.run | bash'
    log "pyenv installed."
else
    sudo -u "$REAL_USER" bash -c '"$HOME/.pyenv/bin/pyenv" update' 2>/dev/null || true
    warn "pyenv already present, updated."
fi

if ! grep -q "pyenv init" "$REAL_HOME/.bashrc"; then
    cat >> "$REAL_HOME/.bashrc" << 'EOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
EOF
    log "pyenv added to ~/.bashrc."
fi

# ── 8. nvm + Node.js LTS ──────────────────────────────────────────────────────
section "nvm + Node.js LTS"
NVM_LATEST=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r '.tag_name')
NVM_DIR="$REAL_HOME/.nvm"

if [ -z "$NVM_LATEST" ] || [ "$NVM_LATEST" = "null" ]; then
    warn "Could not fetch nvm version from GitHub API. Using fallback v0.40.1."
    NVM_LATEST="v0.40.1"
fi

if [ ! -d "$NVM_DIR" ]; then
    sudo -u "$REAL_USER" bash -c \
        "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_LATEST}/install.sh | bash"
    log "nvm ${NVM_LATEST} installed."
else
    warn "nvm already present, skipped."
fi

if ! grep -q "NVM_DIR" "$REAL_HOME/.bashrc"; then
    cat >> "$REAL_HOME/.bashrc" << 'EOF'

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
fi

sudo -u "$REAL_USER" bash -c \
    'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && nvm install --lts && nvm use --lts'
log "Node.js LTS installed/updated."

# ── 9. Docker ─────────────────────────────────────────────────────────────────
section "Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt update -qq
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
log "Docker installed/updated."

if ! groups "$REAL_USER" | grep -q docker; then
    usermod -aG docker "$REAL_USER"
    log "User '$REAL_USER' added to docker group (effective on next login)."
else
    warn "User already in docker group."
fi

# ── 10. DBeaver ───────────────────────────────────────────────────────────────
section "DBeaver"
if ! command -v dbeaver &>/dev/null; then
    wget -qO- https://dbeaver.io/debs/dbeaver.gpg.key \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/dbeaver.gpg
    echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" \
        > /etc/apt/sources.list.d/dbeaver.list
    apt update -qq
    apt install -y dbeaver-ce
    log "DBeaver installed (via APT repo)."
else
    warn "DBeaver already installed, skipped."
fi

# ── 11. Beekeeper Studio ──────────────────────────────────────────────────────
section "Beekeeper Studio"
if ! command -v beekeeper-studio &>/dev/null; then
    wget -qO- https://deb.beekeeperstudio.io/beekeeper.key \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/beekeeper.gpg
    echo "deb [signed-by=/usr/share/keyrings/beekeeper.gpg] https://deb.beekeeperstudio.io stable main" \
        > /etc/apt/sources.list.d/beekeeper-studio.list
    apt update -qq
    apt install -y beekeeper-studio
    log "Beekeeper Studio installed."
else
    warn "Beekeeper Studio already installed, skipped."
fi

# ── 12. Git config ────────────────────────────────────────────────────────────
section "Git global config"
CURRENT_NAME=$(sudo -u "$REAL_USER" git config --global user.name 2>/dev/null || true)
CURRENT_EMAIL=$(sudo -u "$REAL_USER" git config --global user.email 2>/dev/null || true)

if [ -n "$CURRENT_NAME" ] && [ -n "$CURRENT_EMAIL" ]; then
    log "Git already configured: \"$CURRENT_NAME\" <$CURRENT_EMAIL>"
else
    read -rp "GitHub username: " GIT_USERNAME
    read -rp "GitHub email: " GIT_EMAIL
    sudo -u "$REAL_USER" git config --global user.name "$GIT_USERNAME"
    sudo -u "$REAL_USER" git config --global user.email "$GIT_EMAIL"
    log "Git configured: \"$GIT_USERNAME\" <$GIT_EMAIL>"
fi

# ── 13. Fix .bashrc ownership ────────────────────────────────────────────────
chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/.bashrc"
log ".bashrc ownership restored for $REAL_USER."

# ── 14. Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Setup complete! Summary:${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}✔${NC} System updated + 'update' alias"
echo -e "  ${GREEN}✔${NC} git, xclip, htop, jq, tmux"
echo -e "  ${GREEN}✔${NC} bat, ripgrep, fzf, eza"
echo -e "  ${GREEN}✔${NC} Flatpak + Flathub"
echo -e "  ${GREEN}✔${NC} Google Chrome (default browser)"
echo -e "  ${GREEN}✔${NC} Visual Studio Code"
echo -e "  ${GREEN}✔${NC} GitHub CLI (gh)"
echo -e "  ${GREEN}✔${NC} Python venv + pip + pyenv"
echo -e "  ${GREEN}✔${NC} nvm + Node.js LTS + npm"
echo -e "  ${GREEN}✔${NC} Docker + Docker Compose"
echo -e "  ${GREEN}✔${NC} DBeaver (APT repo) + Beekeeper Studio"
echo -e "  ${GREEN}✔${NC} Git configured"
echo ""
echo -e "${YELLOW}  ⚠ Restart your terminal (or run 'source ~/.bashrc') to activate:${NC}"
echo -e "     • aliases: update, bat, ls/ll/tree"
echo -e "     • pyenv"
echo -e "     • nvm"
echo -e "     • docker without sudo"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

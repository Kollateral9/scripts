#!/usr/bin/env bash
# =============================================================
#  setup-git-ssh.sh -- Universal SSH key setup for Git hosts
#
#  Usage examples:
#    ./setup-git-ssh.sh                                     # Interactive: asks for the host
#    ./setup-git-ssh.sh --host github.com                   # GitHub
#    ./setup-git-ssh.sh --config-only                       # Skips SSH, configures ONLY Git identity
#    ./setup-git-ssh.sh --remove-all                        # Deletes all SSH keys from the system
# =============================================================

set -u

GIT_HOST=""
REMOVE_ALL=false
CONFIG_ONLY=false

# ── Parse Arguments ───────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --host|-h) GIT_HOST="$2"; shift ;;
        --remove-all|-R) REMOVE_ALL=true ;;
        --config-only|-C) CONFIG_ONLY=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# ── Colors & Helpers ──────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e " ${GREEN}[OK]${NC} $1"; }
warn()  { echo -e " ${YELLOW}[!]${NC} $1"; }
info()  { echo -e " ${CYAN}[i]${NC} $1"; }
err()   { echo -e " ${RED}[X]${NC} $1"; exit 1; }
rule()  { echo -e "${NC}================================================================="; }
blank() { echo ""; }

# ── Detect provider from hostname ─────────────────────────────
get_git_provider() {
    local host=$1
    if [[ "$host" =~ "github.com" ]]; then echo "GitHub";
    elif [[ "$host" =~ "bitbucket.org" ]]; then echo "Bitbucket";
    elif [[ "$host" =~ "gitlab." ]]; then echo "GitLab";
    else echo "Git"; fi
}

get_ssh_keys_url() {
    local host=$1
    local provider=$2
    case "$provider" in
        "GitHub")    echo "https://$host/settings/keys" ;;
        "Bitbucket") echo "https://$host/account/settings/ssh-keys/" ;;
        "GitLab")    echo "https://$host/-/user_settings/ssh_keys" ;;
        *)           echo "https://$host" ;;
    esac
}

get_test_user() {
    local provider=$1
    if [[ "$provider" == "Bitbucket" ]]; then echo "bitbucket"; else echo "git"; fi
}

get_welcome_pattern() {
    local provider=$1
    case "$provider" in
        "GitHub")    echo "successfully authenticated" ;;
        "Bitbucket") echo "logged in as" ;;
        "GitLab")    echo "Welcome to GitLab" ;;
        *)           echo "." ;; # any output = connected
    esac
}

# ── Banner ────────────────────────────────────────────────────
clear
blank
echo -e "  ${CYAN}Universal Git SSH Setup${NC}"
echo -e "  ${NC}Bash Edition${NC}"
rule
blank

# ── Check prerequisites ───────────────────────────────────────
if ! command -v ssh-keygen &> /dev/null; then
    err "ssh-keygen not found. Please install openssh-client (e.g., sudo apt install openssh-client)."
fi
log "OpenSSH found."

# ── Ensure .ssh directory exists ──────────────────────────────
SSH_DIR="$HOME/.ssh"
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
fi

# ── Function: start ssh-agent ─────────────────────────────────
start_ssh_agent() {
    if [ -z "${SSH_AUTH_SOCK:-}" ] ; then
        eval "$(ssh-agent -s)" > /dev/null
        log "ssh-agent started."
        # Note: the agent started here will keep running after the script exits.
        # To stop it manually: eval "$(ssh-agent -k)"
    else
        log "ssh-agent is already running."
    fi
}

# ── Function: copy to clipboard ───────────────────────────────
copy_to_clipboard() {
    local text="$1"
    if command -v wl-copy &> /dev/null; then
        echo "$text" | wl-copy
        log "Key copied to clipboard (Wayland)!"
    elif command -v xclip &> /dev/null; then
        echo -n "$text" | xclip -selection clipboard
        log "Key copied to clipboard (X11)!"
    elif command -v pbcopy &> /dev/null; then
        echo "$text" | pbcopy
        log "Key copied to clipboard (macOS)!"
    else
        warn "Clipboard tool (xclip/wl-copy) not found. Please copy the text above manually."
    fi
}

# ── REMOVE ALL LOGIC ──────────────────────────────────────────
if [ "$REMOVE_ALL" = true ]; then
    blank
    warn "WARNING: You are about to delete ALL SSH keys in $SSH_DIR!"
    warn "This action cannot be undone and will break existing SSH connections."
    read -p "  Are you absolutely sure? [y/N] " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        blank
        log "Clearing keys from ssh-agent..."
        start_ssh_agent
        ssh-add -D 2>/dev/null

        log "Deleting key files..."
        count=0
        shopt -s nullglob
        for pub in "$SSH_DIR"/*.pub; do
            priv="${pub%.pub}"
            
            rm -f "$pub"
            [ -f "$priv" ] && rm -f "$priv"
            
            ((count++))
        done
        shopt -u nullglob

        log "Successfully deleted $count key pair(s)."
        blank
        rule
        echo -e "  ${GREEN}Cleanup completed. Exiting.${NC}"
        rule
        blank
        exit 0
    else
        blank
        log "Operation cancelled. No keys were deleted. Exiting."
        exit 0
    fi
fi

# ── Function: configure git user (Global or Folder specific) ──
setup_git_config() {
    local email=$1
    local username=$2
    local safename=$3

    if ! command -v git &> /dev/null; then
        warn "git not found in PATH. Skipping git config."
        return
    fi

    blank
    info "Git Identity Configuration"
    info "You can set this identity Globally (for the whole PC)"
    info "or tie it to a Specific Folder (e.g. ~/Projects/Work/)"
    read -p "  Enter the folder path (leave empty for Global): " workspace

    if [ -z "$workspace" ]; then
        # Standard Global Configuration
        git config --global user.name "$username"
        git config --global user.email "$email"
        log "Git configured GLOBALLY: \"$username\" <$email>"
    else
        # Folder-based Configuration (IncludeIf)
        
        # Expand tilde (~) to full home directory path if used
        workspace="${workspace/#\~/$HOME}"

        # Warn about spaces in path (git's includeIf supports it, but it can be fragile)
        if [[ "$workspace" =~ [[:space:]] ]]; then
            warn "Path contains spaces. This works but can be fragile with some tools."
        fi

        if [ ! -d "$workspace" ]; then
            warn "Folder '$workspace' does not exist. Creating it..."
            mkdir -p "$workspace"
        fi

        # Git requires a trailing slash for directories in includeIf
        local git_path="$workspace"
        [[ "${git_path}" != */ ]] && git_path="${git_path}/"

        # Remove trailing slash for path construction
        local stripped_workspace="${workspace%/}"
        
        local specific_config_name=".gitconfig-$safename"
        local specific_config_path="$stripped_workspace/$specific_config_name"

        cat <<EOF > "$specific_config_path"
[user]
    name = $username
    email = $email
EOF
        log "Specific config file created: $specific_config_path"

        # Register the rule in the global .gitconfig
        git config --global "includeIf.gitdir:${git_path}.path" "$specific_config_path"
        log "'includeIf' rule activated for folder: $workspace"
    fi
}

# ── CONFIG ONLY LOGIC ─────────────────────────────────────────
if [ "$CONFIG_ONLY" = true ]; then
    blank
    info "Git Identity Configuration Mode (Skipping SSH Setup)"
    read -p "  Enter your email: " email
    if [ -z "$email" ]; then err "Email not provided. Exiting."; fi

    read -p "  Enter your Git username: " gitUsername
    if [ -z "$gitUsername" ]; then err "Username not provided. Exiting."; fi

    read -p "  Profile name (e.g. work, personal) [default: custom]: " profileName
    profileName=${profileName:-custom}

    setup_git_config "$email" "$gitUsername" "$profileName"
    
    blank
    rule
    echo -e "  ${GREEN}Identity setup completed. Exiting.${NC}"
    rule
    blank
    exit 0
fi

# ── Function: show key, copy, wait for confirmation ───────────
show_key_and_wait() {
    local target_pub_path=$1
    local pubKey
    pubKey=$(cat "$target_pub_path")

    blank
    rule
    echo -e "  ${YELLOW}Add this key to ${PROVIDER}:${NC}"
    echo -e "  ${YELLOW}$KEYS_URL${NC}"
    rule
    blank
    echo "$pubKey"
    blank
    rule

    copy_to_clipboard "$pubKey"

    blank
    read -p "  Press ENTER after adding the key to ${PROVIDER}..."
}

# ── Function: test connection ─────────────────────────────────
test_ssh_connection() {
    log "Testing connection to $GIT_HOST..."
    local result
    result=$(ssh -T "${TEST_USER}@${GIT_HOST}" -o StrictHostKeyChecking=accept-new 2>&1)
    
    if echo "$result" | grep -iq "$WELCOME_PAT"; then
        log "Connection to $GIT_HOST successful!"
        return 0
    else
        warn "Connection completed but non-standard response. Output:"
        echo -e "    $result"
        warn "Test manually: ssh -T ${TEST_USER}@${GIT_HOST}"
        return 1
    fi
}

# ── Function: update ~/.ssh/config ────────────────────────────
update_ssh_config() {
    local key_file_path=$1
    local config_path="$SSH_DIR/config"
    
    if [ -f "$config_path" ]; then
        if grep -q "Host $GIT_HOST" "$config_path"; then
            warn "Host block '$GIT_HOST' already exists in ~/.ssh/config. Skipping."
            return
        fi
    fi

    cat <<EOF >> "$config_path"

Host $GIT_HOST
    HostName $GIT_HOST
    User $TEST_USER
    IdentityFile $key_file_path
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    chmod 600 "$config_path"
    log "Host block added to ~/.ssh/config."
}

# =============================================================
#  MAIN LOGIC
# =============================================================

# ── 1. Check existing keys BEFORE asking for host ─────────────
# Only list .pub files that have a matching private key (skip orphan keys)
existing_keys=()
shopt -s nullglob
for pub in "$SSH_DIR"/*.pub; do
    priv="${pub%.pub}"
    [ -f "$priv" ] && existing_keys+=("$pub")
done
shopt -u nullglob

GENERATE_NEW=true
SELECTED_PUB_PATH=""
SELECTED_KEY_PATH=""

if [ ${#existing_keys[@]} -gt 0 ]; then
    blank
    info "Existing SSH keys found in ~/.ssh/:"
    for i in "${!existing_keys[@]}"; do
        index=$((i+1))
        filename=$(basename "${existing_keys[$i]}")
        echo -e "  [${index}] ${filename}"
    done
    echo -e "  ${GREEN}[0] Create a NEW key${NC}"
    blank

    read -p "  Select an option [0-${#existing_keys[@]}]: " choice
    
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#existing_keys[@]}" ]; then
        GENERATE_NEW=false
        SELECTED_PUB_PATH="${existing_keys[$((choice-1))]}"
        SELECTED_KEY_PATH="${SELECTED_PUB_PATH%.pub}"
        
        log "Selected existing key: $(basename "$SELECTED_PUB_PATH")"
        
        pubKeyContent=$(cat "$SELECTED_PUB_PATH")
        blank
        rule
        echo -e "  ${YELLOW}Key Content:${NC}"
        rule
        echo "$pubKeyContent"
        rule
        
        copy_to_clipboard "$pubKeyContent"
        blank
        
        read -p "  Do you want to proceed and configure a Git Host with this key? [Y/n] " continue_setup
        if [[ "$continue_setup" =~ ^[nN]$ ]]; then
            log "Exiting as requested."
            exit 0
        fi
    elif [ "$choice" == "0" ]; then
        log "Will create a new SSH key."
    else
        err "Invalid selection. Exiting."
    fi
fi

# ── 2. Prompt for host if not passed as parameter ─────────────
if [ -z "$GIT_HOST" ]; then
    blank
    info "Examples: github.com  |  gitlab.com  |  gitlab.eggtronic.it  |  bitbucket.org"
    read -p "  Enter the Git host: " GIT_HOST
    if [ -z "$GIT_HOST" ]; then err "Host not provided. Exiting."; fi
fi

PROVIDER=$(get_git_provider "$GIT_HOST")
KEYS_URL=$(get_ssh_keys_url "$GIT_HOST" "$PROVIDER")
TEST_USER=$(get_test_user "$PROVIDER")
WELCOME_PAT=$(get_welcome_pattern "$PROVIDER")

blank
log "Host:     $GIT_HOST"
log "Provider: $PROVIDER"
rule

# ── Setup Variables ───────────────────────────────────────────
SAFE_NAME="${GIT_HOST//[^a-zA-Z0-9]/_}" # e.g., gitlab_eggtronic_it

if [ "$GENERATE_NEW" = true ]; then
    KEY_PATH="$SSH_DIR/id_ed25519_$SAFE_NAME"
    PUB_PATH="$KEY_PATH.pub"
else
    KEY_PATH="$SELECTED_KEY_PATH"
    PUB_PATH="$SELECTED_PUB_PATH"
fi

if [ "$GENERATE_NEW" = true ]; then

    # ── A. Generate new key ───────────────────────────────────
    blank
    read -p "  Enter your email: " email
    if [ -z "$email" ]; then err "Email not provided. Exiting."; fi

    read -p "  Enter your Git username (name shown on Git commits): " gitUsername
    if [ -z "$gitUsername" ]; then err "Username not provided. Exiting."; fi

    blank
    log "Generating key: $KEY_PATH"
    ssh-keygen -t ed25519 -C "$email" -f "$KEY_PATH" -N ""
    if [ $? -ne 0 ]; then err "Key generation failed."; fi

    start_ssh_agent
    ssh-add "$KEY_PATH"
    if [ $? -eq 0 ]; then log "Key added to the agent."; fi

    update_ssh_config "$KEY_PATH"
    show_key_and_wait "$PUB_PATH"
    test_ssh_connection
    
    setup_git_config "$email" "$gitUsername" "$SAFE_NAME"

else

    # ── B. Use existing selected key ──────────────────────────
    start_ssh_agent
    ssh-add "$KEY_PATH" 2>/dev/null

    update_ssh_config "$KEY_PATH"

    if ! test_ssh_connection; then
        # If it fails, maybe it hasn't been added to the Git server yet
        show_key_and_wait "$PUB_PATH"
        test_ssh_connection
    fi

    blank
    read -p "  Git username for $PROVIDER (for git config): " gitUsername
    
    # Try to extract comment/email from the public key
    # Use cut -f3- to preserve comments that contain spaces (e.g. full names)
    keyComment=$(cut -d' ' -f3- "$PUB_PATH" 2>/dev/null)
    defaultEmail=${keyComment:-""}
    
    read -p "  Email [$defaultEmail]: " gitEmail
    gitEmail=${gitEmail:-$defaultEmail}
    
    setup_git_config "$gitEmail" "$gitUsername" "$SAFE_NAME"
fi

blank
rule
echo -e "  ${GREEN}Setup completed for $GIT_HOST${NC}"
rule
blank

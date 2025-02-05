#!/bin/bash
set -e

# Installation parameters
INSTALL_DIR="$HOME/vaultwarden/scripts"
SCRIPT_NAME="vaultwarden_backup.sh"
INSTALLED_SCRIPT="$INSTALL_DIR/$SCRIPT_NAME"
CRON_TAG="VAULTWARDEN_BACKUP"
CONFIG_DIR="$HOME/.config/vaultwarden_backup"
ACCOUNTS_FILE="$CONFIG_DIR/accounts"
BACKUP_ROOT="$HOME/vaultwarden"
LOG_FILE="$BACKUP_ROOT/scripts/bitwarden_backup.log"

# Self-installation check
if [[ "$(realpath "$0")" != "$(realpath "$INSTALLED_SCRIPT")" ]]; then
    echo "Installing script to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR" "$BACKUP_ROOT"/{exports,tmp} "$CONFIG_DIR"
    chmod 700 "$BACKUP_ROOT"/{exports,tmp}
    cp "$0" "$INSTALLED_SCRIPT"
    chmod +x "$INSTALLED_SCRIPT"
    echo "Installation complete. Re-executing with arguments..."
    exec "$INSTALLED_SCRIPT" "$@"
    exit $?
fi

# Initialize directories
mkdir -p "$BACKUP_ROOT"/{exports,tmp} "$CONFIG_DIR"
chmod 700 "$BACKUP_ROOT"/{exports,tmp}
touch "$ACCOUNTS_FILE"

install_dependencies() {
    echo "Installing required packages..."
    sudo apt update && sudo apt install -y snapd jq libsecret-tools
    sudo snap install bw
    sudo snap connect bw:home
    echo 'export PATH=$PATH:/snap/bin' >> ~/.bashrc
    export PATH=$PATH:/snap/bin
}

generate_cron_time() {
    echo "$(( RANDOM % 59 )) $(( RANDOM % 23 ))"
}

add_account() {
    echo "Adding new Vaultwarden account:"
    read -p "Email: " email
    read -p "Server URL: " server_url
    read -s -p "Bitwarden password: " bw_password
    echo
    read -s -p "Export password: " export_password
    echo

    # Store credentials
    secret-tool store --label="Vaultwarden Email ($email)" service vaultwarden-backup account "${email}_email" <<< "$email"
    secret-tool store --label="Vaultwarden BW Password ($email)" service vaultwarden-backup account "${email}_bw_password" <<< "$bw_password"
    secret-tool store --label="Vaultwarden Export Password ($email)" service vaultwarden-backup account "${email}_export_password" <<< "$export_password"
    secret-tool store --label="Vaultwarden Server URL ($email)" service vaultwarden-backup account "${email}_server_url" <<< "$server_url"

    # Add to accounts list
    if ! grep -qxF "$email" "$ACCOUNTS_FILE"; then
        echo "$email" >> "$ACCOUNTS_FILE"
        # Add cron job with random time
        read -r minute hour <<< "$(generate_cron_time)"
        cron_entry="$minute $hour * * * \"$INSTALLED_SCRIPT\" backup \"$email\" # $CRON_TAG:$email"
        (crontab -l 2>/dev/null | grep -v "# $CRON_TAG:$email"; echo "$cron_entry") | crontab -
        echo "Account added with daily backup at $(printf "%02d" "$hour"):$(printf "%02d" "$minute") UTC"
    else
        echo "Account already exists!"
    fi
}

remove_account() {
    echo "Registered accounts:"
    cat "$ACCOUNTS_FILE"
    read -p "Enter email to remove: " email

    # Remove credentials
    secret-tool clear service vaultwarden-backup account "${email}_email"
    secret-tool clear service vaultwarden-backup account "${email}_bw_password"
    secret-tool clear service vaultwarden-backup account "${email}_export_password"
    secret-tool clear service vaultwarden-backup account "${email}_server_url"

    # Remove from accounts list and cron
    sed -i "/^$email$/d" "$ACCOUNTS_FILE"
    (crontab -l 2>/dev/null | grep -v "# $CRON_TAG:$email") | crontab -
    echo "Account and associated cron job removed"
}

list_accounts() {
    echo "Registered Vaultwarden accounts:"
    cat "$ACCOUNTS_FILE"
    echo -e "\nCron schedule:"
    crontab -l | grep "# $CRON_TAG" | awk '{$6=""; $7=""; print "  " $0}' | sed 's/#.*//'
}

backup() {
    local email="${1:-all}"
    export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/snap/bin
    TIMESTAMP=$(date +%m-%d-%Y-%H-%M)

    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\n=== $(date) ==="

    # Determine accounts to process
    if [[ "$email" != "all" ]]; then
        accounts=("$email")
    else
        mapfile -t accounts < "$ACCOUNTS_FILE"
    fi

    for email in "${accounts[@]}"; do
        [[ -z "$email" ]] && continue

        echo "Processing account: $email"
        
        # Retrieve credentials
        server_url=$(secret-tool lookup service vaultwarden-backup account "${email}_server_url")
        bw_password=$(secret-tool lookup service vaultwarden-backup account "${email}_bw_password")
        export_password=$(secret-tool lookup service vaultwarden-backup account "${email}_export_password")

        # Validate credentials
        if [[ -z "$server_url" || -z "$bw_password" || -z "$export_password" ]]; then
            echo "[$(date)] Error: Missing credentials for $email"
            continue
        fi

        # Configure server
        bw config server "$server_url" &>/dev/null

        # Create temp files
        bw_pass_file=$(mktemp "$BACKUP_ROOT/tmp/bw_pass.XXXXXX")
        export_pw_file=$(mktemp "$BACKUP_ROOT/tmp/export_pw.XXXXXX")
        echo -n "$bw_password" > "$bw_pass_file"
        echo -n "$export_password" > "$export_pw_file"
        chmod 600 "$bw_pass_file" "$export_pw_file"

        # Login and export
        echo "Starting backup for $email..."
        if bw login --raw --passwordfile "$bw_pass_file" "$email" | tee /tmp/bw_session; then
            bw_session=$(cat /tmp/bw_session)
            unlock_session=$(bw unlock --raw --passwordfile "$bw_pass_file" --session "$bw_session")
            
            export_file="$BACKUP_ROOT/exports/vaultwarden-backup-${email}-${TIMESTAMP}.json"
            bw export --format encrypted_json --raw --password "$(cat "$export_pw_file")" --session "$unlock_session" > "$export_file"
            
            bw logout --session "$unlock_session" &>/dev/null
            echo "Backup completed for $email: $export_file"
        else
            echo "Login failed for $email"
        fi

        # Cleanup
        rm -f "$bw_pass_file" "$export_pw_file" /tmp/bw_session
    done
}

uninstall() {
    read -p "This will remove all backups, configurations, and cron jobs. Continue? [y/N] " confirm
    if [[ "$confirm" =~ [yY] ]]; then
        # Remove cron entries
        (crontab -l 2>/dev/null | grep -v "# $CRON_TAG") | crontab -
        
        # Remove directories
        rm -rf "$INSTALL_DIR" "$BACKUP_ROOT" "$CONFIG_DIR"
        
        # Remove secret-tool entries
        while IFS= read -r email; do
            secret-tool clear service vaultwarden-backup account "${email}_email"
            secret-tool clear service vaultwarden-backup account "${email}_bw_password"
            secret-tool clear service vaultwarden-backup account "${email}_export_password"
            secret-tool clear service vaultwarden-backup account "${email}_server_url"
        done < "$ACCOUNTS_FILE"
        
        echo "Vaultwarden backup system completely removed"
    else
        echo "Uninstall cancelled"
    fi
}

case "$1" in
    add)
        install_dependencies
        add_account
        ;;
    remove)
        remove_account
        ;;
    list)
        list_accounts
        ;;
    backup)
        backup "${2:-all}"
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "Usage: $INSTALLED_SCRIPT {add|remove|list|backup|uninstall}"
        echo "Manage multiple Vaultwarden backup accounts:"
        echo "  add        - Add new account with random daily schedule"
        echo "  remove     - Remove existing account"
        echo "  list       - Show registered accounts and schedules"
        echo "  backup     - Run manual backup"
        echo "  uninstall  - Remove all components and cron jobs"
        exit 1
esac

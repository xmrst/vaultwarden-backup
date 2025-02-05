#!/bin/bash
set -e

CONFIG_DIR="$HOME/.config/vaultwarden_backup"
ACCOUNTS_FILE="$CONFIG_DIR/accounts"
BACKUP_ROOT="$HOME/vaultwarden"

# Initialize configuration
mkdir -p "$CONFIG_DIR" "$BACKUP_ROOT"/{scripts,exports,tmp}
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

add_account() {
    # Check dependencies
    if ! command -v bw &> /dev/null || ! command -v secret-tool &> /dev/null; then
        install_dependencies
    fi

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
        echo "Account added successfully!"
    else
        echo "Account already exists!"
    fi
}

remove_account() {
    echo "Registered accounts:"
    cat "$ACCOUNTS_FILE"
    read -p "Enter email to remove: " email

    secret-tool clear service vaultwarden-backup account "${email}_email"
    secret-tool clear service vaultwarden-backup account "${email}_bw_password"
    secret-tool clear service vaultwarden-backup account "${email}_export_password"
    secret-tool clear service vaultwarden-backup account "${email}_server_url"

    sed -i "/^$email$/d" "$ACCOUNTS_FILE"
    echo "Account removed successfully!"
}

list_accounts() {
    echo "Registered Vaultwarden accounts:"
    cat "$ACCOUNTS_FILE"
}

backup() {
    export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/snap/bin
    LOGFILE="$BACKUP_ROOT/scripts/bitwarden_backup.log"

    exec > >(tee -a "$LOGFILE") 2>&1
    echo -e "\n=== $(date) ==="

    while IFS= read -r email; do
        if [[ -z "$email" ]]; then continue; fi

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
            
            export_file="$BACKUP_ROOT/exports/vaultwarden-backup-${email}-$(date +%m-%d-%Y-%H-%M).json"
            bw export --format encrypted_json --raw --password "$(cat "$export_pw_file")" --session "$unlock_session" > "$export_file"
            
            bw logout --session "$unlock_session" &>/dev/null
            echo "Backup completed for $email: $export_file"
        else
            echo "Login failed for $email"
        fi

        # Cleanup
        rm -f "$bw_pass_file" "$export_pw_file" /tmp/bw_session
    done < "$ACCOUNTS_FILE"
}

case "$1" in
    add)
        add_account
        ;;
    remove)
        remove_account
        ;;
    list)
        list_accounts
        ;;
    backup)
        backup
        ;;
    *)
        echo "Usage: $0 {add|remove|list|backup}"
        echo "Manage multiple Vaultwarden backup accounts:"
        echo "  add     - Add new account"
        echo "  remove  - Remove existing account"
        echo "  list    - Show registered accounts"
        echo "  backup  - Run manual backup (automated hourly via cron)"
        exit 1
esac

# First run setup
if [[ ! -f "$BACKUP_ROOT/scripts/bitwarden_backup.sh" ]]; then
    cat > "$BACKUP_ROOT/scripts/bitwarden_backup.sh" << EOF
#!/bin/bash
"$0" backup
EOF
    chmod +x "$BACKUP_ROOT/scripts/bitwarden_backup.sh"
    
    # Add cron job
    cron_entry="0 * * * * $BACKUP_ROOT/scripts/bitwarden_backup.sh"
    if ! crontab -l | grep -qF "$cron_entry"; then
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    fi
fi

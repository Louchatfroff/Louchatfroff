#!/bin/bash

CONFIG_DIR="$HOME/.config/fastfetch"
CONFIG_FILE="$CONFIG_DIR/config.jsonc"
BACKUP_DIR="$CONFIG_DIR/backups"


show_help() {
    echo "Usage: $(basename "$0") [OPTIONS] <URL>"
    echo ""
    echo "Fetch and install a fastfetch config from a URL"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  -n, --no-backup Skip backup of existing config"
    echo "  -p, --preview   Preview the config without installing"
    echo "  -r, --restore   Restore the most recent backup"
    echo "  -l, --list      List available backups"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") https://example.com/config.jsonc"
    echo "  $(basename "$0") -p https://example.com/config.jsonc"
    echo "  $(basename "$0") --restore"
}


list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "No backups found"
        exit 0
    fi

    backups=$(ls -1t "$BACKUP_DIR" 2>/dev/null)
    if [[ -z "$backups" ]]; then
        echo "No backups found"
        exit 0
    fi

    echo "Available backups:"
    echo "$backups" | nl -w2 -s'. '
}


restore_backup() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "Error: No backups directory found"
        exit 1
    fi

    latest=$(ls -1t "$BACKUP_DIR" | head -n1)
    if [[ -z "$latest" ]]; then
        echo "Error: No backups found"
        exit 1
    fi

    cp "$BACKUP_DIR/$latest" "$CONFIG_FILE"
    echo "Restored: $latest"
}


fetch_config() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl -fsSL "$url"
    elif command -v wget &>/dev/null; then
        wget -qO- "$url"
    else
        echo "Error: curl or wget required" >&2
        exit 1
    fi
}


NO_BACKUP=false
PREVIEW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -n|--no-backup)
            NO_BACKUP=true
            shift
            ;;
        -p|--preview)
            PREVIEW=true
            shift
            ;;
        -r|--restore)
            restore_backup
            exit 0
            ;;
        -l|--list)
            list_backups
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            URL="$1"
            shift
            ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo "Error: URL required"
    echo ""
    show_help
    exit 1
fi


echo "Fetching config from: $URL"
config_content=$(fetch_config "$URL")

if [[ $? -ne 0 ]] || [[ -z "$config_content" ]]; then
    echo "Error: Failed to fetch config"
    exit 1
fi


if $PREVIEW; then
    echo ""
    echo "--- Config Preview ---"
    echo "$config_content"
    echo "----------------------"
    exit 0
fi


mkdir -p "$CONFIG_DIR"
mkdir -p "$BACKUP_DIR"


if [[ -f "$CONFIG_FILE" ]] && ! $NO_BACKUP; then
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="$BACKUP_DIR/config_$timestamp.jsonc"
    cp "$CONFIG_FILE" "$backup_file"
    echo "Backup saved: $backup_file"
fi


echo "$config_content" > "$CONFIG_FILE"
echo "Config installed: $CONFIG_FILE"


if command -v fastfetch &>/dev/null; then
    echo ""
    echo "--- Preview ---"
    fastfetch
fi

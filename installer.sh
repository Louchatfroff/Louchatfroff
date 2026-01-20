#!/bin/bash

CONFIG_DIR="$HOME/.config/fastfetch"
CONFIG_FILE="$CONFIG_DIR/config.jsonc"
CONFIG_ROOT_V1="$HOME/.config/config.jsonc"
CONFIG_ROOT_V2="$HOME/.config/config-v2.jsonc"
BACKUP_DIR="$CONFIG_DIR/backups"
THEME_NAME="Tokyo Night"


TN_BLUE='\033[38;2;123;162;243m'
TN_MAGENTA='\033[38;2;187;154;247m'
TN_CYAN='\033[38;2;45;206;234m'
TN_WHITE='\033[38;2;192;202;245m'
RESET='\033[0m'


print_header() {
    echo -e "${TN_BLUE}"
    echo "╔═══════════════════════════════════════════╗"
    echo "║                                           ║"
    echo -e "║  ${TN_MAGENTA}  Tokyo Night Fastfetch Installer ${TN_BLUE}     ║"
    echo "║                                           ║"
    echo "╚═══════════════════════════════════════════╝"
    echo -e "${RESET}"
}


check_fastfetch() {
    if ! command -v fastfetch &>/dev/null; then
        echo -e "${TN_MAGENTA}Warning: fastfetch is not installed${RESET}"
        echo ""
        echo "Install it with:"
        echo "  Arch:   sudo pacman -S fastfetch"
        echo "  Debian: sudo apt install fastfetch"
        echo "  Fedora: sudo dnf install fastfetch"
        echo ""
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}


backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        mkdir -p "$BACKUP_DIR"
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_file="$BACKUP_DIR/config_$timestamp.jsonc"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${TN_CYAN}Backup saved: $backup_file${RESET}"
    fi
}


install_config() {
    mkdir -p "$CONFIG_DIR"

    config_content=$(cat << 'CONFIGEND'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",


    "display": {
        "separator": " ",
        "color": {
            "keys": "blue",
            "output": "white"
        }
    },


    "logo": {
        "type": "auto",
        "color": {
            "1": "blue",
            "2": "magenta",
            "3": "cyan"
        }
    },


    "modules": [
        {
            "type": "custom",
            "format": "\u001b[38;2;123;162;243m《·───────────────·》◈《·──────────────·》"
        },
        {
            "type": "os",
            "key": "  OS",
            "keyColor": "blue"
        },
        {
            "type": "kernel",
            "key": "  Kernel",
            "keyColor": "blue"
        },
        {
            "type": "uptime",
            "key": "  Uptime",
            "keyColor": "magenta"
        },
        {
            "type": "packages",
            "key": "  Packages",
            "keyColor": "magenta"
        },
        {
            "type": "de",
            "key": "  DE",
            "keyColor": "cyan"
        },
        {
            "type": "wm",
            "key": "  WM",
            "keyColor": "cyan"
        },
        {
            "type": "terminal",
            "key": "  Terminal",
            "keyColor": "blue"
        },
        {
            "type": "shell",
            "key": "  Shell",
            "keyColor": "blue"
        },
        {
            "type": "cpu",
            "key": "  CPU",
            "keyColor": "magenta"
        },
        {
            "type": "gpu",
            "key": "  GPU",
            "keyColor": "magenta"
        },
        {
            "type": "memory",
            "key": "  Memory",
            "keyColor": "cyan"
        },
        {
            "type": "disk",
            "key": "  Disk",
            "keyColor": "cyan"
        },
        {
            "type": "display",
            "key": "  Resolution",
            "keyColor": "blue"
        },
        {
            "type": "theme",
            "key": "  Theme",
            "keyColor": "blue"
        },
        {
            "type": "icons",
            "key": "  Icons",
            "keyColor": "magenta"
        },
        {
            "type": "font",
            "key": "  Font",
            "keyColor": "magenta"
        },
        {
            "type": "custom",
            "format": "\u001b[38;2;123;162;243m《·───────────────·》◈《·───────────────·》"
        },
        {
            "type": "custom",
            "format": "\u001b[38;2;65;72;104m● \u001b[38;2;123;162;243m● \u001b[38;2;187;154;247m● \u001b[38;2;45;206;234m● \u001b[38;2;65;181;155m● \u001b[38;2;224;175;104m● \u001b[38;2;187;194;224m● \u001b[38;2;192;202;245m● "
        }
    ]
}
CONFIGEND
)

    echo "$config_content" > "$CONFIG_FILE"
    echo -e "${TN_CYAN}Installed: $CONFIG_FILE${RESET}"

    echo "$config_content" > "$CONFIG_ROOT_V1"
    echo -e "${TN_CYAN}Installed: $CONFIG_ROOT_V1${RESET}"

    echo "$config_content" > "$CONFIG_ROOT_V2"
    echo -e "${TN_CYAN}Installed: $CONFIG_ROOT_V2${RESET}"
}


show_preview() {
    if command -v fastfetch &>/dev/null; then
        echo ""
        echo -e "${TN_MAGENTA}Preview:${RESET}"
        echo ""
        fastfetch
    fi
}


uninstall() {
    removed=false

    if [[ -f "$CONFIG_FILE" ]]; then
        rm "$CONFIG_FILE"
        echo -e "${TN_CYAN}Removed: $CONFIG_FILE${RESET}"
        removed=true
    fi

    if [[ -f "$CONFIG_ROOT_V1" ]]; then
        rm "$CONFIG_ROOT_V1"
        echo -e "${TN_CYAN}Removed: $CONFIG_ROOT_V1${RESET}"
        removed=true
    fi

    if [[ -f "$CONFIG_ROOT_V2" ]]; then
        rm "$CONFIG_ROOT_V2"
        echo -e "${TN_CYAN}Removed: $CONFIG_ROOT_V2${RESET}"
        removed=true
    fi

    if ! $removed; then
        echo "No config files to remove"
        return
    fi

    if [[ -d "$BACKUP_DIR" ]]; then
        latest=$(ls -1t "$BACKUP_DIR" 2>/dev/null | head -n1)
        if [[ -n "$latest" ]]; then
            read -p "Restore previous fastfetch config? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cp "$BACKUP_DIR/$latest" "$CONFIG_FILE"
                echo -e "${TN_CYAN}Restored: $latest${RESET}"
            fi
        fi
    fi
}


show_help() {
    echo "Usage: $(basename "$0") [OPTION]"
    echo ""
    echo "Install Tokyo Night theme for fastfetch"
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help"
    echo "  -u, --uninstall  Remove the theme"
    echo "  -p, --preview    Preview without installing"
    echo "  -f, --force      Install without confirmation"
}


FORCE=false
PREVIEW_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -u|--uninstall)
            print_header
            uninstall
            exit 0
            ;;
        -p|--preview)
            PREVIEW_ONLY=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done


print_header
check_fastfetch

if $PREVIEW_ONLY; then
    echo -e "${TN_CYAN}Config preview (not installed):${RESET}"
    echo ""
    cat << 'PREVIEWEND'
Theme: Tokyo Night
Colors: Blue (#7ba2f3), Magenta (#bb9af7), Cyan (#2dceea)
Modules: OS, Kernel, Uptime, Packages, DE, WM, Terminal,
         Shell, CPU, GPU, Memory, Disk, Resolution,
         Theme, Icons, Font
PREVIEWEND
    exit 0
fi

if ! $FORCE; then
    echo -e "${TN_WHITE}This will install the $THEME_NAME fastfetch theme${RESET}"
    echo ""
    read -p "Continue? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

backup_config
install_config
show_preview

echo ""
echo -e "${TN_MAGENTA}Done!${RESET}"

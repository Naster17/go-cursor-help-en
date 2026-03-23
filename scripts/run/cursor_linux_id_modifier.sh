#!/bin/bash

# Set error handling
set -e

# Define log file path
LOG_FILE="/tmp/cursor_linux_id_modifier.log"

# Initialize log file
initialize_log() {
    echo "========== Cursor ID Modifier Tool Log Start $(date) ==========" > "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# When explicitly disabled, turn off TTY UI (resize/clear/Logo) to avoid garbled output in some environments
if [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
    CURSOR_NO_TTY_UI=1
fi

# UI/Color switch: follows NO_COLOR standard, supports CURSOR_NO_TTY_UI (disables fancy TTY UI)
if [ -n "${NO_COLOR:-}" ] || [ -n "${CURSOR_NO_COLOR:-}" ] || [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Try to resize terminal window to 120x40 (cols x rows) on startup; silently ignore if not supported/failed to avoid affecting main script flow
try_resize_terminal_window() {
    local target_cols=120
    local target_rows=40

    # Can be explicitly disabled via CURSOR_NO_TTY_UI to avoid garbled output in some environments
    if [ -n "${CURSOR_NO_TTY_UI:-}" ]; then
        return 0
    fi

    # Only try in interactive terminal to avoid garbled output when redirected
    if [ ! -t 1 ]; then
        return 0
    fi

    case "${TERM:-}" in
        ""|dumb)
            return 0
            ;;
    esac

    # Terminal type detection: only attempt window resize for common xterm-based terminals (GNOME Terminal/Konsole/xterm/Terminator etc. are usually xterm*)
    case "${TERM:-}" in
        xterm*|screen*|tmux*|rxvt*|alacritty*|kitty*|foot*|wezterm*)
            ;;
        *)
            return 0
            ;;
    esac

    # Prefer xterm window control sequences; need passthrough wrapper under tmux/screen
    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033[8;%d;%dt\033\\' "$target_rows" "$target_cols" 2>/dev/null || true
    elif [ -n "${STY:-}" ]; then
        printf '\033P\033[8;%d;%dt\033\\' "$target_rows" "$target_cols" 2>/dev/null || true
    else
        printf '\033[8;%d;%dt' "$target_rows" "$target_cols" 2>/dev/null || true
    fi

    return 0
}

# Log functions - output to both terminal and log file
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Log command output to log file
log_cmd_output() {
    local cmd="$1"
    local msg="$2"
    echo "[CMD] $(date '+%Y-%m-%d %H:%M:%S') Executing command: $cmd" >> "$LOG_FILE"
    echo "[CMD] $msg:" >> "$LOG_FILE"
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# sed -i compatibility wrapper: prefer in-place edit; fall back to temp file replacement if not supported/failed, improving cross-distro compatibility
sed_inplace() {
    local expr="$1"
    local file="$2"

    # GNU sed / BusyBox sed: usually supports sed -i
    if sed -i "$expr" "$file" 2>/dev/null; then
        return 0
    fi

    # BSD sed: requires -i '' form (rare environments)
    if sed -i '' "$expr" "$file" 2>/dev/null; then
        return 0
    fi

    # Final fallback: temp file replacement (avoids different sed -i semantics)
    local temp_file
    temp_file=$(mktemp) || return 1
    if sed "$expr" "$file" > "$temp_file"; then
        cat "$temp_file" > "$file"
        rm -f "$temp_file"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

# Path resolution compatibility: prefer realpath; fall back to readlink -f / python3 / cd+pwd (avoid triggering set -e on missing commands)
resolve_path() {
    local target="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$target" 2>/dev/null && return 0
    fi

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$target" 2>/dev/null && return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null && return 0
    fi

    # Final fallback: don't resolve symlinks, just return absolute path as best effort
    if [ -d "$target" ]; then
        (cd "$target" 2>/dev/null && pwd -P) && return 0
    fi
    local dir
    dir=$(dirname "$target")
    (cd "$dir" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$(basename "$target")") && return 0

    echo "$target"
    return 0
}

# Get current user
get_current_user() {
    # sudo scenario: prefer SUDO_USER as target user (Cursor usually runs under this user)
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
        return 0
    fi

    # Normal/direct root scenario: use current effective user
    if command -v id >/dev/null 2>&1; then
        id -un 2>/dev/null && return 0
    fi
    echo "${USER:-}"
}

# Get specified user's Home directory (compatible with sudo/root/container scenarios)
get_user_home_dir() {
    local user="$1"
    local home=""

    if command -v getent >/dev/null 2>&1; then
        home=$(getent passwd "$user" 2>/dev/null | awk -F: '{print $6}' | head -n 1)
    fi
    if [ -z "$home" ] && [ -f /etc/passwd ]; then
        home=$(awk -F: -v u="$user" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null)
    fi
    if [ -z "$home" ]; then
        home=$(eval echo "~$user" 2>/dev/null)
    fi

    # Fallback: use current environment HOME if unable to resolve
    if [ -z "$home" ] || [[ "$home" == "~"* ]]; then
        home="${HOME:-}"
    fi

    echo "$home"
}

# Get specified user's primary group (chown needs user:group; different distros may have different id parameter/output)
get_user_primary_group() {
    local user="$1"
    local group=""
    local gid=""

    # Priority: get primary group name directly (cleanest)
    if command -v id >/dev/null 2>&1; then
        group=$(id -gn "$user" 2>/dev/null | tr -d '\r\n') || true
        if [ -n "$group" ]; then
            echo "$group"
            return 0
        fi

        # Fallback: get gid first, then map to group name (if mapping fails return gid, which chown can also use)
        gid=$(id -g "$user" 2>/dev/null | tr -d '\r\n') || true
    fi

    if [ -n "$gid" ]; then
        if command -v getent >/dev/null 2>&1; then
            group=$(getent group "$gid" 2>/dev/null | awk -F: '{print $1}' | head -n 1) || true
        fi
        if [ -z "$group" ] && [ -f /etc/group ]; then
            group=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' /etc/group 2>/dev/null) || true
        fi

        if [ -n "$group" ]; then
            echo "$group"
            return 0
        fi

        echo "$gid"
        return 0
    fi

    # Final fallback: return user itself (some systems allow user:user)
    echo "$user"
    return 0
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "Unable to get username"
    exit 1
fi

# 🎯 Unified "target user/target Home": all subsequent Cursor user data paths are based on this Home
TARGET_HOME=$(get_user_home_dir "$CURRENT_USER")
if [ -z "$TARGET_HOME" ]; then
    log_error "Unable to resolve target user Home directory: $CURRENT_USER"
    exit 1
fi
log_info "Target user: $CURRENT_USER"
log_info "Target user Home: $TARGET_HOME"

# 🎯 Unified "target user primary group": no longer relies on id -g -n compatibility for chown
CURRENT_GROUP=$(get_user_primary_group "$CURRENT_USER")
if [ -z "$CURRENT_GROUP" ]; then
    CURRENT_GROUP="$CURRENT_USER"
    log_warn "Unable to resolve target user primary group, fallback to: $CURRENT_GROUP (subsequent chown may fail)"
else
    log_info "Target user primary group: $CURRENT_GROUP"
fi

# Define Cursor paths on Linux
CURSOR_CONFIG_DIR="$TARGET_HOME/.config/Cursor"
STORAGE_FILE="$CURSOR_CONFIG_DIR/User/globalStorage/storage.json"
BACKUP_DIR="$CURSOR_CONFIG_DIR/User/globalStorage/backups"

# Shared IDs (for consistency between config and JS injection)
CURSOR_ID_MACHINE_ID=""
CURSOR_ID_MACHINE_GUID=""
CURSOR_ID_MAC_MACHINE_ID=""
CURSOR_ID_DEVICE_ID=""
CURSOR_ID_SQM_ID=""
CURSOR_ID_FIRST_SESSION_DATE=""
CURSOR_ID_SESSION_ID=""
CURSOR_ID_MAC_ADDRESS="00:11:22:33:44:55"

# --- New: Installation related variables ---
APPIMAGE_SEARCH_DIR="/opt/CursorInstall" # AppImage search directory, can be modified as needed
APPIMAGE_PATTERN="Cursor-*.AppImage"     # AppImage filename pattern
INSTALL_DIR="/opt/Cursor"                # Cursor final installation directory
ICON_PATH="/usr/share/icons/cursor.png"
DESKTOP_FILE="/usr/share/applications/cursor-cursor.desktop"
# --- End: Installation related variables ---

# Possible Cursor binary paths - added standard installation path
CURSOR_BIN_PATHS=(
    "/usr/bin/cursor"
    "/usr/local/bin/cursor"
    "$INSTALL_DIR/cursor"               # Added standard installation path
    "$TARGET_HOME/.local/bin/cursor"
    "/snap/bin/cursor"
)

# Find Cursor installation path
find_cursor_path() {
    log_info "Searching for Cursor installation path..."
    
    for path in "${CURSOR_BIN_PATHS[@]}"; do
        if [ -f "$path" ] && [ -x "$path" ]; then # Ensure file exists and is executable
            log_info "Found Cursor installation path: $path"
            CURSOR_PATH="$path"
            return 0
        fi
    done

    # Try to locate via command -v
    if command -v cursor &> /dev/null; then
        # Compatibility fix: some distros don't have which; command -v can directly return path
        CURSOR_PATH=$(command -v cursor)
        log_info "Found Cursor via command -v: $CURSOR_PATH"
        return 0
    fi
    
    # Try to find possible installation paths (limit search scope and type)
    # Compatibility fix: find's -executable may not be available in BusyBox, and find errors returning non-zero will trigger set -e; unified fallback handling here
    local cursor_paths=""

    # Priority: use -executable (if supported)
    cursor_paths=$(find /usr /opt "$TARGET_HOME/.local" -type f -name "cursor" -executable 2>/dev/null || true)

    # Fallback: don't rely on -executable, use shell filtering for executables
    if [ -z "$cursor_paths" ]; then
        cursor_paths=$(find /usr /opt "$TARGET_HOME/.local" -type f -name "cursor" 2>/dev/null || true)
        cursor_paths=$(echo "$cursor_paths" | while IFS= read -r p; do [ -n "$p" ] && [ -x "$p" ] && echo "$p"; done)
    fi

    # Extra fallback: prioritize standard installation path
    if [ -x "$INSTALL_DIR/cursor" ]; then
        cursor_paths="$INSTALL_DIR/cursor"$'\n'"$cursor_paths"
    fi
    if [ -n "$cursor_paths" ]; then
        # Prioritize standard installation path
        local standard_path=$(echo "$cursor_paths" | grep "$INSTALL_DIR/cursor" | head -1)
        if [ -n "$standard_path" ]; then
            CURSOR_PATH="$standard_path"
        else
            CURSOR_PATH=$(echo "$cursor_paths" | head -1)
        fi
        log_info "Found Cursor via search: $CURSOR_PATH"
        return 0
    fi
    
    log_warn "Cursor executable not found"
    return 1
}

# Find and locate Cursor resources directory
find_cursor_resources() {
    log_info "Searching for Cursor resources directory..."
    
    # Possible resource directory paths - added standard installation directory
    local resource_paths=(
        "$INSTALL_DIR" # Added standard installation path
        "/usr/lib/cursor"
        "/usr/share/cursor"
        "$TARGET_HOME/.local/share/cursor"
    )
    
    for path in "${resource_paths[@]}"; do
        if [ -d "$path/resources" ]; then # Check if resources subdirectory exists
            log_info "Found Cursor resources directory: $path"
            CURSOR_RESOURCES="$path"
            return 0
        fi
         if [ -d "$path/app" ]; then # Some versions may have app directory directly
             log_info "Found Cursor resources directory (app): $path"
             CURSOR_RESOURCES="$path"
             return 0
         fi
    done
    
    # If CURSOR_PATH exists, try to infer from it
    if [ -n "$CURSOR_PATH" ]; then
        local base_dir=$(dirname "$CURSOR_PATH")
        # Check common relative paths
        if [ -d "$base_dir/resources" ]; then
            CURSOR_RESOURCES="$base_dir"
            log_info "Found resources directory via binary path: $CURSOR_RESOURCES"
            return 0
        elif [ -d "$base_dir/../resources" ]; then # e.g., inside bin directory
            CURSOR_RESOURCES=$(resolve_path "$base_dir/..")
            log_info "Found resources directory via binary path: $CURSOR_RESOURCES"
            return 0
        elif [ -d "$base_dir/../lib/cursor/resources" ]; then # Another common structure
            CURSOR_RESOURCES=$(resolve_path "$base_dir/../lib/cursor")
            log_info "Found resources directory via binary path: $CURSOR_RESOURCES"
            return 0
        fi
    fi
    
    log_warn "Cursor resources directory not found"
    return 1
}

# Check permissions
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run this script with sudo (installation and modifying system files requires privileges)"
        echo "Example: sudo $0"
        exit 1
    fi
}

# --- New/Refactored: Install Cursor from local AppImage ---
install_cursor_appimage() {
    log_info "Starting attempt to install Cursor from local AppImage..."
    local found_appimage_path=""

    # Ensure search directory exists
    mkdir -p "$APPIMAGE_SEARCH_DIR"

    # Find AppImage file
    find_appimage() {
        # Compatibility fix: find parameters may vary across implementations, and find non-zero exit will trigger set -e; unified fallback to success here
        found_appimage_path=$(find "$APPIMAGE_SEARCH_DIR" -maxdepth 1 -name "$APPIMAGE_PATTERN" -print -quit 2>/dev/null || true)
        if [ -z "$found_appimage_path" ]; then
            return 1
        else
            return 0
        fi
    }

    if ! find_appimage; then
        log_warn "No '$APPIMAGE_PATTERN' file found in directory '$APPIMAGE_SEARCH_DIR'."
        # --- New: Add filename format reminder ---
        log_info "Please ensure AppImage filename format is similar to: Cursor-version-architecture.AppImage (e.g., Cursor-1.0.6-aarch64.AppImage or Cursor-x.y.z-x86_64.AppImage)"
        # --- End: Add filename format reminder ---
        # Wait for user to place file
        read -p $"Please place the Cursor AppImage file in directory '$APPIMAGE_SEARCH_DIR', then press Enter to continue..."

        # Search again
        if ! find_appimage; then
            log_error "Still cannot find '$APPIMAGE_PATTERN' file in '$APPIMAGE_SEARCH_DIR'. Installation aborted."
            return 1
        fi
    fi

    log_info "Found AppImage file: $found_appimage_path"
    local appimage_filename=$(basename "$found_appimage_path")

    # Enter search directory to avoid path issues
    local current_dir=$(pwd)
    cd "$APPIMAGE_SEARCH_DIR" || { log_error "Cannot enter directory: $APPIMAGE_SEARCH_DIR"; return 1; }

    log_info "Setting executable permission for '$appimage_filename'..."
    chmod +x "$appimage_filename" || {
        log_error "Failed to set executable permission: $appimage_filename"
        cd "$current_dir"
        return 1
    }

    log_info "Extracting AppImage file '$appimage_filename'..."
    # Create temporary extraction directory
    local extract_dir="squashfs-root"
    rm -rf "$extract_dir" # Clean up old extraction directory (if exists)
    
    # Perform extraction, redirect output to avoid interference
    if ./"$appimage_filename" --appimage-extract > /dev/null; then
        log_info "AppImage extracted successfully to '$extract_dir'"
    else
        log_error "Failed to extract AppImage: $appimage_filename"
        rm -rf "$extract_dir" # Clean up failed extraction
        cd "$current_dir"
        return 1
    fi

    # Check expected directory structure after extraction
    local cursor_source_dir=""
    if [ -d "$extract_dir/usr/share/cursor" ]; then
       cursor_source_dir="$extract_dir/usr/share/cursor"
    elif [ -d "$extract_dir" ]; then # Some AppImages may be directly in root
       # Further check if key files/directories exist
       if [ -f "$extract_dir/cursor" ] && [ -d "$extract_dir/resources" ]; then
           cursor_source_dir="$extract_dir"
       fi
    fi

    if [ -z "$cursor_source_dir" ]; then
        log_error "Expected Cursor file structure not found in extracted directory '$extract_dir' (e.g., 'usr/share/cursor' or containing 'cursor' and 'resources' directly)."
        rm -rf "$extract_dir"
        cd "$current_dir"
        return 1
    fi
     log_info "Found Cursor source files at: $cursor_source_dir"


    log_info "Installing Cursor to '$INSTALL_DIR'..."
    # If installation directory exists, remove first (ensure fresh install)
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "Found existing installation directory '$INSTALL_DIR', will remove first..."
        rm -rf "$INSTALL_DIR" || { log_error "Failed to remove old installation directory: $INSTALL_DIR"; cd "$current_dir"; return 1; }
    fi
    
    # Create parent directory of installation directory (if needed) and set permissions
    mkdir -p "$(dirname "$INSTALL_DIR")"
    
    # Move extracted content to installation directory
    if mv "$cursor_source_dir" "$INSTALL_DIR"; then
        log_info "Successfully moved files to '$INSTALL_DIR'"
        # Ensure installation directory and contents belong to current user (if needed)
        chown -R "$CURRENT_USER":"$CURRENT_GROUP" "$INSTALL_DIR" || log_warn "Failed to set file ownership for '$INSTALL_DIR', may need manual adjustment"
        chmod -R u+rwX,go+rX,go-w "$INSTALL_DIR" || log_warn "Failed to set file permissions for '$INSTALL_DIR', may need manual adjustment"
    else
        log_error "Failed to move files to installation directory '$INSTALL_DIR'"
        rm -rf "$extract_dir" # Ensure cleanup
        rm -rf "$INSTALL_DIR" # Clean up partially moved files
        cd "$current_dir"
        return 1
    fi

    # Handle icon and desktop shortcut (search from script's original execution directory)
    cd "$current_dir" # Return to original directory to find icons etc.

    local icon_source="./cursor.png"
    local desktop_source="./cursor-cursor.desktop"

    if [ -f "$icon_source" ]; then
        log_info "Installing icon..."
        mkdir -p "$(dirname "$ICON_PATH")"
        cp "$icon_source" "$ICON_PATH" || log_warn "Cannot copy icon file '$icon_source' to '$ICON_PATH'"
        chmod 644 "$ICON_PATH" || log_warn "Failed to set icon file permissions: $ICON_PATH"
    else
        log_warn "Icon file '$icon_source' does not exist in script's current directory, skipping icon installation."
        log_warn "Please place 'cursor.png' file in script directory '$current_dir' and re-run installation (if icon is needed)."
    fi

    if [ -f "$desktop_source" ]; then
        log_info "Installing desktop shortcut..."
         mkdir -p "$(dirname "$DESKTOP_FILE")"
        cp "$desktop_source" "$DESKTOP_FILE" || log_warn "Cannot create desktop shortcut '$desktop_source' to '$DESKTOP_FILE'"
        chmod 644 "$DESKTOP_FILE" || log_warn "Failed to set desktop file permissions: $DESKTOP_FILE"

        # Update desktop database
        log_info "Updating desktop database..."
        update-desktop-database "$(dirname "$DESKTOP_FILE")" &> /dev/null || log_warn "Cannot update desktop database, shortcut may not appear immediately"
    else
        log_warn "Desktop file '$desktop_source' does not exist in script's current directory, skipping shortcut installation."
         log_warn "Please place 'cursor-cursor.desktop' file in script directory '$current_dir' and re-run installation (if shortcut is needed)."
    fi

    # Create symbolic link to /usr/local/bin
    log_info "Creating command line launch link..."
    ln -sf "$INSTALL_DIR/cursor" /usr/local/bin/cursor || log_warn "Cannot create command line link '/usr/local/bin/cursor'"

    # Clean up temporary files
    log_info "Cleaning up temporary files..."
    cd "$APPIMAGE_SEARCH_DIR" # Return to search directory for cleanup
    rm -rf "$extract_dir"
    log_info "Deleting original AppImage file: $found_appimage_path"
    rm -f "$appimage_filename" # Delete AppImage file

    cd "$current_dir" # Ensure return to final directory

    log_info "Cursor installed successfully! Installation directory: $INSTALL_DIR"
    return 0
}
# --- End: Installation function ---

# Check and stop Cursor process

# Get Cursor related process PIDs (compatible with pgrep/ps multiple implementations)
get_cursor_pids() {
    local self_pid="$$"
    local pids=""

    # Priority: use pgrep (more stable): match only by process name, avoid false matches to script command line (e.g., sudo bash ...cursor_linux_id_modifier.sh)
    if command -v pgrep >/dev/null 2>&1; then
        pids=$(pgrep -i "cursor" 2>/dev/null || true)
        if [ -z "$pids" ]; then
            pids=$(pgrep "cursor" 2>/dev/null || true)
        fi
        if [ -z "$pids" ]; then
            pids=$(pgrep "Cursor" 2>/dev/null || true)
        fi

        if [ -n "$pids" ]; then
            echo "$pids" | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' | sort -u
            return 0
        fi
    fi

    # Fallback: compatible with different ps implementations (BusyBox may not support aux / -ef)
    if ps aux >/dev/null 2>&1; then
        ps aux 2>/dev/null \
            | grep -i '[c]ursor' \
            | grep -v "cursor_linux_id_modifier.sh" \
            | awk '{print $2}' \
            | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
            | sort -u
        return 0
    fi

    if ps -ef >/dev/null 2>&1; then
        ps -ef 2>/dev/null \
            | grep -i '[c]ursor' \
            | grep -v "cursor_linux_id_modifier.sh" \
            | awk '{print $2}' \
            | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
            | sort -u
        return 0
    fi

    ps 2>/dev/null \
        | grep -i '[c]ursor' \
        | grep -v "cursor_linux_id_modifier.sh" \
        | awk '{print $1}' \
        | awk -v self="$self_pid" '$1 ~ /^[0-9]+$/ && $1 != self {print $1}' \
        | sort -u
    return 0
}

# Print Cursor related process details (for troubleshooting; doesn't rely on fixed column structure)
print_cursor_process_details() {
    log_debug "Getting Cursor process details:"

    if ps aux >/dev/null 2>&1; then
        ps aux 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
        return 0
    fi

    if ps -ef >/dev/null 2>&1; then
        ps -ef 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
        return 0
    fi

    ps 2>/dev/null | grep -i '[c]ursor' | grep -v "cursor_linux_id_modifier.sh" || true
    return 0
}

check_and_kill_cursor() {
    log_info "Checking Cursor processes..."
    
    local attempt=1
    local max_attempts=5
    
    while [ $attempt -le $max_attempts ]; do
        # Cross-distro compatibility: prefer pgrep, then compatible with ps aux/ps -ef/ps PID column differences
        local cursor_pids_raw
        cursor_pids_raw=$(get_cursor_pids || true)
        # Convert newline-separated PID list to space-separated for kill (avoid dependency on xargs)
        CURSOR_PIDS=$(echo "$cursor_pids_raw" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            log_info "No running Cursor processes found"
            return 0
        fi
        
        log_warn "Found Cursor processes running: $CURSOR_PIDS"
        print_cursor_process_details
        
        log_warn "Attempting to stop Cursor processes..."
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "Attempting to force kill processes..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        # Check again if processes are still running
        if [ -z "$(get_cursor_pids | head -n 1)" ]; then
            log_info "Cursor processes successfully stopped"
            return 0
        fi
        
        log_warn "Waiting for processes to stop, attempt $attempt/$max_attempts..."
        ((attempt++))
    done
    
    log_error "Unable to stop Cursor processes after $max_attempts attempts"
    print_cursor_process_details
    log_error "Please manually close processes and retry"
    exit 1
}

# Backup configuration file
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "Configuration file '$STORAGE_FILE' does not exist, skipping backup"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    
    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        # Ensure backup file ownership is correct
        chown "$CURRENT_USER":"$CURRENT_GROUP" "$backup_file" || log_warn "Failed to set backup file ownership: $backup_file"
        log_info "Configuration backed up to: $backup_file"
    else
        log_error "Backup failed: $STORAGE_FILE"
        exit 1
    fi
    return 0 # Explicitly return success
}

# Generate random ID
generate_hex_bytes() {
    local bytes="$1"

    # Priority: use openssl
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
        return 0
    fi

    # Fallback: /dev/urandom + od (available on most distros)
    if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        # Use more generic od parameter syntax for broader distro compatibility
        od -An -N "$bytes" -t x1 /dev/urandom | tr -d ' \n'
        return 0
    fi

    # Final fallback: if python3 is available
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, sys; print(os.urandom(int(sys.argv[1])).hex())' "$bytes"
        return 0
    fi

    log_error "Missing openssl/od/python3, cannot generate random bytes (bytes=$bytes)"
    return 1
}

generate_random_id() {
    # Generate 32 bytes (64 hex characters) of random data
    generate_hex_bytes 32
}

# Generate random UUID
generate_uuid() {
    # Use uuidgen on Linux
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Alternative: use /proc/sys/kernel/random/uuid
        if [ -f /proc/sys/kernel/random/uuid ]; then
            cat /proc/sys/kernel/random/uuid
        else
            # Final alternative: use random 16 bytes and format (avoid sed capture group >9 compatibility issues)
            local hex
            hex=$(generate_hex_bytes 16) || return 1
            echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
        fi
    fi
}

# Normalize machineId (ensure it's a hex string)
normalize_machine_id() {
    local raw="$1"
    local cleaned
    cleaned=$(echo "$raw" | tr -d '-' | tr '[:upper:]' '[:lower:]')
    if [[ "$cleaned" =~ ^[0-9a-f]{32,}$ ]]; then
        echo "$cleaned"
        return 0
    fi
    return 1
}

# Read IDs from existing config (for JS injection consistency)
load_ids_from_storage() {
    if [ ! -f "$STORAGE_FILE" ]; then
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not detected, cannot read IDs from existing config"
        return 1
    fi

    local output
    output=$(python3 - "$STORAGE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def pick(keys):
    for k in keys:
        v = data.get(k)
        if isinstance(v, str) and v:
            return v
    return ""

items = {
    "machineId": pick(["telemetry.machineId", "machineId"]),
    "macMachineId": pick(["telemetry.macMachineId"]),
    "devDeviceId": pick(["telemetry.devDeviceId", "deviceId"]),
    "sqmId": pick(["telemetry.sqmId"]),
    "firstSessionDate": pick(["telemetry.firstSessionDate"]),
}

for k, v in items.items():
    print(f"{k}={v}")
PY
)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        return 1
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            machineId) CURSOR_ID_MACHINE_ID="$value" ;;
            macMachineId) CURSOR_ID_MAC_MACHINE_ID="$value" ;;
            devDeviceId) CURSOR_ID_DEVICE_ID="$value" ;;
            sqmId) CURSOR_ID_SQM_ID="$value" ;;
            firstSessionDate) CURSOR_ID_FIRST_SESSION_DATE="$value" ;;
        esac
    done <<< "$output"

    if [ -n "$CURSOR_ID_MACHINE_ID" ]; then
        local normalized
        if normalized=$(normalize_machine_id "$CURSOR_ID_MACHINE_ID"); then
            if [ "$normalized" != "$CURSOR_ID_MACHINE_ID" ]; then
                log_warn "machineId non-standard format, JS injection will use value without hyphens"
            fi
            CURSOR_ID_MACHINE_ID="$normalized"
        else
            log_warn "machineId not recognized as hex, JS injection will use new value"
            CURSOR_ID_MACHINE_ID=""
        fi
    fi

    CURSOR_ID_SESSION_ID=$(generate_uuid)
    CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"

    if [ -n "$CURSOR_ID_MACHINE_ID" ] && [ -n "$CURSOR_ID_MAC_MACHINE_ID" ] && [ -n "$CURSOR_ID_DEVICE_ID" ] && [ -n "$CURSOR_ID_SQM_ID" ]; then
        return 0
    fi
    return 1
}

# Generate IDs for JS injection only (don't write to config)
generate_ids_for_js_only() {
    CURSOR_ID_MACHINE_ID=$(generate_random_id)
    CURSOR_ID_MACHINE_GUID=$(generate_uuid)
    CURSOR_ID_MAC_MACHINE_ID=$(generate_random_id)
    CURSOR_ID_DEVICE_ID=$(generate_uuid)
    CURSOR_ID_SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    CURSOR_ID_FIRST_SESSION_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    CURSOR_ID_SESSION_ID=$(generate_uuid)
    CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"
}

# Modify existing file
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if [ ! -f "$file" ]; then
        log_error "Configuration file does not exist: $file"
        return 1
    fi
    
    # Ensure file is writable by current user (root)
    chmod u+w "$file" || {
        log_error "Cannot modify file permissions (write): $file"
        return 1
    }
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Check if key exists
    if grep -q "\"$key\":[[:space:]]*\"[^\"]*\"" "$file"; then
        # Key exists, perform replacement (more precise matching)
        sed "s/\\(\"$key\"\\):[[:space:]]*\"[^\"]*\"/\\1: \"$value\"/" "$file" > "$temp_file" || {
            log_error "Failed to modify config (replace): $key in $file"
            rm -f "$temp_file"
            chmod u-w "$file" # Restore permissions
            return 1
        }
         log_debug "Replaced key '$key' in file '$file'"
    elif grep -q "}" "$file"; then
         # Key doesn't exist, add new key-value pair before last '}'
         # Note: This method is fragile and will fail if JSON format is non-standard or last line is not '}'
         # 🔧 Compatibility fix: Don't rely on GNU sed \n replacement extension; also avoid generating invalid JSON when `}` is on its own line
         if tail -n 1 "$file" | grep -Eq '^[[:space:]]*}[[:space:]]*$'; then
             # Multi-line JSON: Insert new line before last `}`, and add comma to previous property
             awk -v key="$key" -v value="$value" '
             { lines[NR] = $0 }
             END {
                 brace = 0
                 for (i = NR; i >= 1; i--) {
                     if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) { brace = i; break }
                 }
                 if (brace == 0) { exit 2 }

                 prev = 0
                 for (i = brace - 1; i >= 1; i--) {
                     if (lines[i] !~ /^[[:space:]]*$/) { prev = i; break }
                 }
                 if (prev > 0) {
                     line = lines[prev]
                     sub(/[[:space:]]*$/, "", line)
                     if (line !~ /{$/ && line !~ /,$/) {
                         lines[prev] = line ","
                     } else {
                         lines[prev] = line
                     }
                 }

                 insert_line = "    \"" key "\": \"" value "\""
                 for (i = 1; i <= NR; i++) {
                     if (i == brace) { print insert_line }
                     print lines[i]
                 }
             }
             ' "$file" > "$temp_file" || {
                 log_error "Failed to add config (inject): $key to $file"
                 rm -f "$temp_file"
                 chmod u-w "$file" # Restore permissions
                 return 1
             }
         else
             # Single-line JSON: Insert key-value before ending `}` (avoid relying on sed \n extension)
             sed "s/}[[:space:]]*$/,\"$key\": \"$value\"}/" "$file" > "$temp_file" || {
                 log_error "Failed to add config (inject): $key to $file"
                 rm -f "$temp_file"
                 chmod u-w "$file" # Restore permissions
                 return 1
             }
         fi
         log_debug "Added key '$key' to file '$file'"
    else
         log_error "Unable to determine how to add config: $key to $file (file structure may be non-standard)"
         rm -f "$temp_file"
         chmod u-w "$file" # Restore permissions
         return 1
    fi

    # Check if temp file is valid
    if [ ! -s "$temp_file" ]; then
        log_error "Temp file is empty after modifying or adding config: $key in $file"
        rm -f "$temp_file"
        chmod u-w "$file" # Restore permissions
        return 1
    fi
    
    # Use cat to replace original file content
    cat "$temp_file" > "$file" || {
        log_error "Failed to write updated config to file: $file"
        rm -f "$temp_file"
        # Try to restore permissions (no harm if it fails)
        chmod u-w "$file" || true
        return 1
    }
    
    rm -f "$temp_file"
    
    # Set owner and base permissions (when running as root, target file is in user's home directory)
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$file" || log_warn "Failed to set file ownership: $file"
    chmod 644 "$file" || log_warn "Failed to set file permissions: $file" # User read/write, group and others read
    
    return 0
}

# Generate new config
generate_new_config() {
    echo
    log_warn "Machine code reset option"
    
    # Use menu selection function to ask user whether to reset machine code
    set +e
    # Default select "Reset" to meet the "default should handle all" requirement
    select_menu_option "Do you need to reset machine code? (Default: Reset and sync modify config file): " "Do not reset - Only modify js file is enough|Reset - Modify both config file and machine code" 1
    reset_choice=$?
    set -e
    
    # Log for debugging
    echo "[INPUT_DEBUG] Machine code reset option selected: $reset_choice" >> "$LOG_FILE"
    
    # Ensure config file directory exists
    mkdir -p "$(dirname "$STORAGE_FILE")"
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$(dirname "$STORAGE_FILE")" || log_warn "Failed to set config directory ownership: $(dirname "$STORAGE_FILE")"
    chmod 755 "$(dirname "$STORAGE_FILE")" || log_warn "Failed to set config directory permissions: $(dirname "$STORAGE_FILE")"

    # Handle user selection - index 0 corresponds to "Do not reset" option, index 1 corresponds to "Reset" option
    if [ "$reset_choice" = "1" ]; then
        log_info "You selected to reset machine code"
        
        # Check if config file exists
        if [ -f "$STORAGE_FILE" ]; then
            log_info "Found existing config file: $STORAGE_FILE"
            
            # Backup existing config
            if ! backup_config; then # If backup fails, do not continue modification
                 log_error "Config file backup failed, aborting machine code reset."
                 return 1 # Return error status
            fi
            
            # Generate and set new device ID
            local new_device_id=$(generate_uuid)
            local new_machine_id=$(generate_random_id)
            # 🔧 Added: serviceMachineId (for storage.serviceMachineId)
            local new_service_machine_id=$(generate_uuid)
            # 🔧 Added: firstSessionDate (reset first session date)
            local new_first_session_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
            # 🔧 Added: macMachineId and sqmId
            local new_mac_machine_id=$(generate_random_id)
            local new_sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"

            CURSOR_ID_MACHINE_ID="$new_machine_id"
            CURSOR_ID_MAC_MACHINE_ID="$new_mac_machine_id"
            CURSOR_ID_DEVICE_ID="$new_device_id"
            CURSOR_ID_SQM_ID="$new_sqm_id"
            CURSOR_ID_FIRST_SESSION_DATE="$new_first_session_date"
            CURSOR_ID_SESSION_ID=$(generate_uuid)
            CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"

            log_info "Setting new device and machine IDs..."
            log_debug "New device ID: $new_device_id"
            log_debug "New machine ID: $new_machine_id"
            log_debug "New serviceMachineId: $new_service_machine_id"
            log_debug "New firstSessionDate: $new_first_session_date"

            # Modify config file
            # 🔧 Fix: Add storage.serviceMachineId, telemetry.firstSessionDate, telemetry.macMachineId, telemetry.sqmId
            local config_success=true
            modify_or_add_config "deviceId" "$new_device_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "machineId" "$new_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.machineId" "$new_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.macMachineId" "$new_mac_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.devDeviceId" "$new_device_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.sqmId" "$new_sqm_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "storage.serviceMachineId" "$new_service_machine_id" "$STORAGE_FILE" || config_success=false
            modify_or_add_config "telemetry.firstSessionDate" "$new_first_session_date" "$STORAGE_FILE" || config_success=false

            if [ "$config_success" = true ]; then
                log_info "All identifiers in config file modified successfully"
                log_info "📋 [Details] Updated the following identifiers:"
                echo "   🔹 deviceId: ${new_device_id:0:16}..."
                echo "   🔹 machineId: ${new_machine_id:0:16}..."
                echo "   🔹 macMachineId: ${new_mac_machine_id:0:16}..."
                echo "   🔹 sqmId: $new_sqm_id"
                echo "   🔹 serviceMachineId: $new_service_machine_id"
                echo "   🔹 firstSessionDate: $new_first_session_date"

                # 🔧 Added: Modify machineid file
                log_info "🔧 [machineid] Modifying machineid file..."
                local machineid_file_path="$CURSOR_CONFIG_DIR/machineid"
                if [ -f "$machineid_file_path" ]; then
                    # Backup original machineid file
                    local machineid_backup="$BACKUP_DIR/machineid.backup_$(date +%Y%m%d_%H%M%S)"
                    cp "$machineid_file_path" "$machineid_backup" 2>/dev/null && \
                        log_info "💾 [Backup] machineid file backed up: $machineid_backup"
                fi
                # Write new serviceMachineId to machineid file
                if echo -n "$new_service_machine_id" > "$machineid_file_path" 2>/dev/null; then
                    log_info "✅ [machineid] machineid file modified successfully: $new_service_machine_id"
                    # Set machineid file to read-only
                    chmod 444 "$machineid_file_path" 2>/dev/null && \
                        log_info "🔒 [Protect] machineid file set to read-only"
                else
                    log_warn "⚠️  [machineid] machineid file modification failed"
                    log_info "💡 [Tip] Can manually modify file: $machineid_file_path"
                fi

                # 🔧 Added: Modify .updaterId file (updater device identifier)
                log_info "🔧 [updaterId] Modifying .updaterId file..."
                local updater_id_file_path="$CURSOR_CONFIG_DIR/.updaterId"
                if [ -f "$updater_id_file_path" ]; then
                    # Backup original .updaterId file
                    local updater_id_backup="$BACKUP_DIR/.updaterId.backup_$(date +%Y%m%d_%H%M%S)"
                    cp "$updater_id_file_path" "$updater_id_backup" 2>/dev/null && \
                        log_info "💾 [Backup] .updaterId file backed up: $updater_id_backup"
                fi
                # Generate new updaterId (UUID format)
                local new_updater_id=$(generate_uuid)
                if echo -n "$new_updater_id" > "$updater_id_file_path" 2>/dev/null; then
                    log_info "✅ [updaterId] .updaterId file modified successfully: $new_updater_id"
                    # Set .updaterId file to read-only
                    chmod 444 "$updater_id_file_path" 2>/dev/null && \
                        log_info "🔒 [Protect] .updaterId file set to read-only"
                else
                    log_warn "⚠️  [updaterId] .updaterId file modification failed"
                    log_info "💡 [Tip] Can manually modify file: $updater_id_file_path"
                fi
            else
                log_error "Some identifiers in config file failed to modify"
                # Note: Even if failed, backup still exists, but config file may be partially modified
                return 1 # Return error status
            fi
        else
            log_warn "Config file '$STORAGE_FILE' not found, cannot reset machine code. This is normal if this is the first installation."
            # Even if file doesn't exist, consider this step (not executed) as "successful", allow to continue
        fi
    else
        log_info "You selected not to reset machine code, will only modify js files"
        
        # Check if config file exists and backup (if exists)
        if [ -f "$STORAGE_FILE" ]; then
            log_info "Found existing config file: $STORAGE_FILE"
            if ! backup_config; then
                 log_error "Config file backup failed, aborting operation."
                 return 1 # Return error status
            fi
            if load_ids_from_storage; then
                log_info "IDs read from existing config, JS injection will remain consistent"
            else
                log_warn "Unable to read IDs from existing config, JS injection will use newly generated IDs (config will not be modified)"
                generate_ids_for_js_only
            fi
        else
            log_warn "Config file '$STORAGE_FILE' not found, skipping backup."
            log_warn "Unable to read existing IDs, JS injection will use newly generated IDs (config will not be modified)"
            generate_ids_for_js_only
        fi
    fi
    
    echo
    log_info "Config processing completed"
    return 0 # Explicitly return success
}

# Find Cursor JS files
find_cursor_js_files() {
    log_info "Finding Cursor JS files..."
    
    local js_files=()
    local found=false
    
    # Ensure CURSOR_RESOURCES is set
    if [ -z "$CURSOR_RESOURCES" ] || [ ! -d "$CURSOR_RESOURCES" ]; then
        log_error "Cursor resources directory not found or invalid ($CURSOR_RESOURCES), cannot find JS files."
        return 1
    fi

    log_debug "Searching for JS files in resources directory: $CURSOR_RESOURCES"
    
    # Recursively search for specific JS files in resources directory
    # Note: These patterns may need to be updated based on Cursor version
    local js_patterns=(
        "resources/app/out/vs/workbench/api/node/extensionHostProcess.js"
        "resources/app/out/main.js"
        "resources/app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
        "resources/app/out/vs/code/node/cliProcessMain.js"
        # Add other possible path patterns
        "app/out/vs/workbench/api/node/extensionHostProcess.js" # If resources directory is parent of app
        "app/out/main.js"
        "app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
        "app/out/vs/code/node/cliProcessMain.js"
    )
    
    for pattern in "${js_patterns[@]}"; do
        # Use find to locate full path under CURSOR_RESOURCES
        # Compatibility fix: find returning non-zero on error may trigger set -e, here uniformly fallback to successful return
        local files=$(find "$CURSOR_RESOURCES" -path "*/$pattern" -type f 2>/dev/null || true)
        if [ -n "$files" ]; then
            while IFS= read -r file; do
                # Check if file has already been added
                if [[ ! " ${js_files[@]} " =~ " ${file} " ]]; then
                    log_info "Found JS file: $file"
                    js_files+=("$file")
                    found=true
                fi
            done <<< "$files"
        fi
    done
    
    # If still not found, try more general search (may have false positives)
    if [ "$found" = false ]; then
        log_warn "JS files not found in standard path patterns, trying broader search in resources directory '$CURSOR_RESOURCES'..."
        # Find JS files containing specific keywords
        local files=$(find "$CURSOR_RESOURCES" -name "*.js" -type f -exec grep -lE 'IOPlatformUUID|x-cursor-checksum|getMachineId' {} \; 2>/dev/null || true)
        if [ -n "$files" ]; then
            while IFS= read -r file; do
                 if [[ ! " ${js_files[@]} " =~ " ${file} " ]]; then
                     log_info "Found possible JS file by keyword: $file"
                     js_files+=("$file")
                     found=true
                 fi
            done <<< "$files"
        else
             log_warn "Also failed to find JS files by keyword in resources directory '$CURSOR_RESOURCES'."
        fi
    fi

    if [ "$found" = false ]; then
        log_error "No modifiable JS files found in resources directory '$CURSOR_RESOURCES'."
        log_error "Please check if Cursor installation is complete, or if JS path patterns in script need updating."
        return 1
    fi
    
    # Deduplicate (theoretically handled by above check, but just in case)
    IFS=" " read -r -a CURSOR_JS_FILES <<< "$(echo "${js_files[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    
    log_info "Found ${#CURSOR_JS_FILES[@]} unique JS files to process."
    return 0
}

# Modify Cursor JS files
# 🔧 Modify Cursor core JS files to bypass device identification (enhanced triple solution)
# Plan A: someValue placeholder replacement - stable anchor, does not depend on obfuscated function names
# Plan B: b6 fixed-point rewrite - machine code source function directly returns fixed value
# Plan C: Loader Stub + external Hook - main/shared process only loads external Hook file
modify_cursor_js_files() {
    log_info "🔧 [Core Modification] Starting to modify Cursor core JS files to bypass device identification..."
    log_info "💡 [Solution] Using enhanced triple solution: placeholder replacement + b6 fixed-point rewrite + Loader Stub + external Hook"

    # First find JS files that need to be modified
    if ! find_cursor_js_files; then
        return 1
    fi

    if [ ${#CURSOR_JS_FILES[@]} -eq 0 ]; then
        log_error "JS file list is empty, cannot continue modification."
        return 1
    fi

    # Generate or reuse device identifiers (prefer values read from config)
    local machine_id="${CURSOR_ID_MACHINE_ID:-}"
    local machine_guid="${CURSOR_ID_MACHINE_GUID:-}"
    local device_id="${CURSOR_ID_DEVICE_ID:-}"
    local mac_machine_id="${CURSOR_ID_MAC_MACHINE_ID:-}"
    local sqm_id="${CURSOR_ID_SQM_ID:-}"
    local session_id="${CURSOR_ID_SESSION_ID:-}"
    local first_session_date="${CURSOR_ID_FIRST_SESSION_DATE:-}"
    local mac_address="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"
    local ids_missing=false

    if [ -z "$machine_id" ]; then
        machine_id=$(generate_random_id)
        ids_missing=true
    fi
    if [ -z "$machine_guid" ]; then
        machine_guid=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$device_id" ]; then
        device_id=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$mac_machine_id" ]; then
        mac_machine_id=$(generate_random_id)
        ids_missing=true
    fi
    if [ -z "$sqm_id" ]; then
        sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
        ids_missing=true
    fi
    if [ -z "$session_id" ]; then
        session_id=$(generate_uuid)
        ids_missing=true
    fi
    if [ -z "$first_session_date" ]; then
        first_session_date=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
        ids_missing=true
    fi

    if [ "$ids_missing" = true ]; then
        log_warn "Some IDs not obtained from config, new values generated for JS injection"
    else
        log_info "Using device identifiers from config for JS injection"
    fi

    CURSOR_ID_MACHINE_ID="$machine_id"
    CURSOR_ID_MACHINE_GUID="$machine_guid"
    CURSOR_ID_DEVICE_ID="$device_id"
    CURSOR_ID_MAC_MACHINE_ID="$mac_machine_id"
    CURSOR_ID_SQM_ID="$sqm_id"
    CURSOR_ID_SESSION_ID="$session_id"
    CURSOR_ID_FIRST_SESSION_DATE="$first_session_date"
    CURSOR_ID_MAC_ADDRESS="$mac_address"

    log_info "🔑 [Prepare] Device identifiers ready"
    log_info "   machineId: ${machine_id:0:16}..."
    log_info "   machineGuid: ${machine_guid:0:16}..."
    log_info "   deviceId: ${device_id:0:16}..."
    log_info "   macMachineId: ${mac_machine_id:0:16}..."
    log_info "   sqmId: $sqm_id"

    # Delete old config and regenerate on each execution to ensure new device identifiers are obtained
    local ids_config_path="$TARGET_HOME/.cursor_ids.json"
    if [ -f "$ids_config_path" ]; then
        rm -f "$ids_config_path"
        log_info "🗑️  [Cleanup] Deleted old ID config file"
    fi
    cat > "$ids_config_path" << EOF
{
  "machineId": "$machine_id",
  "machineGuid": "$machine_guid",
  "macMachineId": "$mac_machine_id",
  "devDeviceId": "$device_id",
  "sqmId": "$sqm_id",
  "macAddress": "$mac_address",
  "sessionId": "$session_id",
  "firstSessionDate": "$first_session_date",
  "createdAt": "$first_session_date"
}
EOF
    chown "$CURRENT_USER":"$CURRENT_GROUP" "$ids_config_path" 2>/dev/null || true
    log_info "💾 [Save] New ID config saved to: $ids_config_path"

    # Deploy external Hook file (for Loader Stub to load, supports multiple domain fallback downloads)
    local hook_target_path="$TARGET_HOME/.cursor_hook.js"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local hook_source_path="$script_dir/../hook/cursor_hook.js"
    local hook_download_urls=(
        "https://wget.la/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://down.npee.cn/?https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://xget.xi-xu.me/gh/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh-proxy.com/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh.chjina.com/https://raw.githubusercontent.com/yuaotian/go-cursor-help/refs/heads/master/scripts/hook/cursor_hook.js"
    )
    # Support overriding download nodes via environment variable (comma-separated)
    if [ -n "$CURSOR_HOOK_DOWNLOAD_URLS" ]; then
        IFS=',' read -r -a hook_download_urls <<< "$CURSOR_HOOK_DOWNLOAD_URLS"
        log_info "ℹ️  [Hook] Detected custom download node list, will prioritize"
    fi

    if [ -f "$hook_source_path" ]; then
        if cp "$hook_source_path" "$hook_target_path"; then
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
            log_info "✅ [Hook] External Hook deployed: $hook_target_path"
        else
            log_warn "⚠️  [Hook] Local Hook copy failed, trying online download..."
        fi
    fi

    if [ ! -f "$hook_target_path" ]; then
        log_info "ℹ️  [Hook] Downloading external Hook for device identifier interception..."
        local hook_downloaded=false
        local total_urls=${#hook_download_urls[@]}
        if [ "$total_urls" -eq 0 ]; then
            log_warn "⚠️  [Hook] Download node list is empty, skipping online download"
        elif command -v curl >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) Current download node: $url"

                # Compatibility fix: some curl versions may not support --progress-bar, fallback to basic params on failure
                if curl -fL --progress-bar "$url" -o "$hook_target_path"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] External Hook downloaded online: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] curl download failed, trying fallback params: $url"
                if curl -fL "$url" -o "$hook_target_path"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] External Hook downloaded online: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] External Hook download failed: $url"
            done
        elif command -v wget >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) Current download node: $url"

                # Compatibility fix: BusyBox/minimal wget may not support --progress=bar:force, fallback to basic params on failure
                if wget --progress=bar:force -O "$hook_target_path" "$url"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] External Hook downloaded online: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] wget download failed, trying fallback params: $url"
                if wget -O "$hook_target_path" "$url"; then
                    chown "$CURRENT_USER":"$CURRENT_GROUP" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] External Hook downloaded online: $hook_target_path"
                    hook_downloaded=true
                    break
                fi

                rm -f "$hook_target_path"
                log_warn "⚠️  [Hook] External Hook download failed: $url"
            done
        else
            log_warn "⚠️  [Hook] curl/wget not detected, cannot download Hook online"
        fi
        if [ "$hook_downloaded" != true ] && [ ! -f "$hook_target_path" ]; then
            log_warn "⚠️  [Hook] External Hook all downloads failed"
        fi
    fi

    local modified_count=0
    local file_modification_status=()

    # Process each file: create original backup or restore from original backup
    for file in "${CURSOR_JS_FILES[@]}"; do
        log_info "📝 [Process] Processing: $(basename "$file")"

        if [ ! -f "$file" ]; then
            log_error "File does not exist: $file, skipping."
            file_modification_status+=("'$(basename "$file")': Not Found")
            continue
        fi

        # Create backup directory
        local backup_dir="$(dirname "$file")/backups"
        mkdir -p "$backup_dir" 2>/dev/null || true

        local file_name=$(basename "$file")
        local original_backup="$backup_dir/$file_name.original"

        # If original backup does not exist, create it first
        if [ ! -f "$original_backup" ]; then
            # Check if current file has already been modified
            if grep -q "__cursor_patched__" "$file" 2>/dev/null; then
                log_warn "⚠️  [Warning] File has been modified but no original backup exists, will use current version as base"
            fi
            cp "$file" "$original_backup"
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$original_backup" 2>/dev/null || true
            chmod 444 "$original_backup" 2>/dev/null || true
            log_info "✅ [Backup] Original backup created successfully: $file_name"
        else
            # Restore from original backup to ensure clean injection each time
            log_info "🔄 [Restore] Restoring from original backup: $file_name"
            cp "$original_backup" "$file"
        fi

        # Create timestamp backup (record state before each modification)
        local backup_file="$backup_dir/$file_name.backup_$(date +%Y%m%d_%H%M%S)"
        if ! cp "$file" "$backup_file"; then
            log_error "Unable to create file backup: $file"
            file_modification_status+=("'$(basename "$file")': Backup Failed")
            continue
        fi
        chown "$CURRENT_USER":"$CURRENT_GROUP" "$backup_file" 2>/dev/null || true
        chmod 444 "$backup_file" 2>/dev/null || true

        chmod u+w "$file" || {
            log_error "Unable to modify file permissions (write): $file"
            file_modification_status+=("'$(basename "$file")': Permission Error")
            continue
        }

        local replaced=false

        # ========== Method A: someValue placeholder replacement (stable anchor) ==========
        # Important notes:
        # In current Cursor's main.js, placeholders usually appear as string literals, e.g.:
        #   this.machineId="someValue.machineId"
        # If we directly replace someValue.machineId with "\"<real_value>\"", it will form ""<real_value>"" causing JS syntax error.
        # Therefore, here we prioritize replacing complete string literals (including outer quotes), then fallback to replacing unquoted placeholders.
        if grep -q 'someValue\.machineId' "$file"; then
            sed_inplace "s/\"someValue\.machineId\"/\"${machine_id}\"/g" "$file"
            sed_inplace "s/'someValue\.machineId'/\"${machine_id}\"/g" "$file"
            sed_inplace "s/someValue\.machineId/\"${machine_id}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.machineId"
            replaced=true
        fi

        if grep -q 'someValue\.macMachineId' "$file"; then
            sed_inplace "s/\"someValue\.macMachineId\"/\"${mac_machine_id}\"/g" "$file"
            sed_inplace "s/'someValue\.macMachineId'/\"${mac_machine_id}\"/g" "$file"
            sed_inplace "s/someValue\.macMachineId/\"${mac_machine_id}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.macMachineId"
            replaced=true
        fi

        if grep -q 'someValue\.devDeviceId' "$file"; then
            sed_inplace "s/\"someValue\.devDeviceId\"/\"${device_id}\"/g" "$file"
            sed_inplace "s/'someValue\.devDeviceId'/\"${device_id}\"/g" "$file"
            sed_inplace "s/someValue\.devDeviceId/\"${device_id}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.devDeviceId"
            replaced=true
        fi

        if grep -q 'someValue\.sqmId' "$file"; then
            sed_inplace "s/\"someValue\.sqmId\"/\"${sqm_id}\"/g" "$file"
            sed_inplace "s/'someValue\.sqmId'/\"${sqm_id}\"/g" "$file"
            sed_inplace "s/someValue\.sqmId/\"${sqm_id}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.sqmId"
            replaced=true
        fi

        if grep -q 'someValue\.sessionId' "$file"; then
            sed_inplace "s/\"someValue\.sessionId\"/\"${session_id}\"/g" "$file"
            sed_inplace "s/'someValue\.sessionId'/\"${session_id}\"/g" "$file"
            sed_inplace "s/someValue\.sessionId/\"${session_id}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.sessionId"
            replaced=true
        fi

        if grep -q 'someValue\.firstSessionDate' "$file"; then
            sed_inplace "s/\"someValue\.firstSessionDate\"/\"${first_session_date}\"/g" "$file"
            sed_inplace "s/'someValue\.firstSessionDate'/\"${first_session_date}\"/g" "$file"
            sed_inplace "s/someValue\.firstSessionDate/\"${first_session_date}\"/g" "$file"
            log_info "   ✓ [Plan A] Replace someValue.firstSessionDate"
            replaced=true
        fi

        # ========== Method B: b6 fixed-point rewrite (machine code source function, main.js only) ==========
        local b6_patched=false
        if [ "$(basename "$file")" = "main.js" ]; then
            if command -v python3 >/dev/null 2>&1; then
                local b6_result
                b6_result=$(python3 - "$file" "$machine_guid" "$machine_id" <<'PY'
# 🔧 Fix: Use standard 4-space indentation to avoid IndentationError
import re, sys

def diag(msg):
    print(f"[Plan B][Diagnostics] {msg}", file=sys.stderr)

path, machine_guid, machine_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

# ✅ 1+3 fusion: limit to out-build/vs/base/node/id.js module for feature matching + brace pairing to locate function boundaries
marker = "out-build/vs/base/node/id.js"
marker_index = data.find(marker)
if marker_index < 0:
    print("NOT_FOUND")
    diag(f"Module marker not found: {marker}")
    raise SystemExit(0)

window_end = min(len(data), marker_index + 200000)
window = data[marker_index:window_end]

def find_matching_brace(text, open_index, max_scan=20000):
    limit = min(len(text), open_index + max_scan)
    depth = 1
    in_single = in_double = in_template = False
    in_line_comment = in_block_comment = False
    escape = False
    i = open_index + 1
    while i < limit:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < limit else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue

        if in_single:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_double = False
            i += 1
            continue
        if in_template:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "`":
                in_template = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue

        if ch == "'":
            in_single = True
            i += 1
            continue
        if ch == '"':
            in_double = True
            i += 1
            continue
        if ch == "`":
            in_template = True
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i

        i += 1
    return None

# 🔧 Fix: Avoid syntax errors from raw string + single quotes + ['"] character groups; also fix regex escaping to improve b6 feature matching hit rate
hash_re = re.compile(r"""createHash\(["']sha256["']\)""")
sig_re = re.compile(r'^async function (\w+)\((\w+)\)')

hash_matches = list(hash_re.finditer(window))
diag(f"marker_index={marker_index} window_len={len(window)} sha256_createHash={len(hash_matches)}")

for idx, hm in enumerate(hash_matches, start=1):
    hash_pos = hm.start()
    func_start = window.rfind("async function", 0, hash_pos)
    if func_start < 0:
        if idx <= 3:
            diag(f"Candidate#{idx}: async function start not found")
        continue

    open_brace = window.find("{", func_start)
    if open_brace < 0:
        if idx <= 3:
            diag(f"Candidate#{idx}: Function opening brace not found")
        continue

    end_brace = find_matching_brace(window, open_brace, max_scan=20000)
    if end_brace is None:
        if idx <= 3:
            diag(f"Candidate#{idx}: Brace pairing failed (not closed within scan limit)")
        continue

    func_text = window[func_start:end_brace + 1]
    if len(func_text) > 8000:
        if idx <= 3:
            diag(f"Candidate#{idx}: Function body too long len={len(func_text)}, skipped")
        continue

    sm = sig_re.match(func_text)
    if not sm:
        if idx <= 3:
            diag(f"Candidate#{idx}: Function signature not parsed (async function name(param))")
        continue
    name, param = sm.group(1), sm.group(2)

    # Feature validation: sha256 + hex digest + return param ? raw : hash
    has_digest = re.search(r"""\.digest\(["']hex["']\)""", func_text) is not None
    has_return = re.search(r'return\s+' + re.escape(param) + r'\?\w+:\w+\}', func_text) is not None
    if idx <= 3:
        diag(f"Candidate#{idx}: {name}({param}) len={len(func_text)} digest={has_digest} return={has_return}")
    if not has_digest:
        continue
    if not has_return:
        continue

    replacement = f'async function {name}({param}){{return {param}?"{machine_guid}":"{machine_id}";}}'
    abs_start = marker_index + func_start
    abs_end = marker_index + end_brace
    new_data = data[:abs_start] + replacement + data[abs_end + 1:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_data)
    diag(f"Hit and rewrite: {name}({param}) len={len(func_text)}")
    print("PATCHED")
    break
else:
    diag("No candidate function meeting features found")
    print("NOT_FOUND")
PY
                 )
                if [ "$b6_result" = "PATCHED" ]; then
                    log_info "   ✓ [Plan B] Rewrote b6 feature function"
                    b6_patched=true
                else
                    log_warn "⚠️  [Plan B] b6 feature function not located"
                fi
            else
                log_warn "⚠️  [Plan B] python3 not detected, skipping b6 fixed-point rewrite"
            fi
        fi

        # ========== Method C: Loader Stub Injection ==========
        local inject_code='// ========== Cursor Hook Loader Start ==========
;(async function(){/*__cursor_patched__*/
"use strict";
if(globalThis.__cursor_hook_loaded__)return;
globalThis.__cursor_hook_loaded__=true;

try{
    // Compatibility ESM/CJS: avoid using import.meta (ESM only), uniformly use dynamic import to load Hook
    var fsMod=await import("fs");
    var pathMod=await import("path");
    var osMod=await import("os");
    var urlMod=await import("url");

    var fs=fsMod&&(fsMod.default||fsMod);
    var path=pathMod&&(pathMod.default||pathMod);
    var os=osMod&&(osMod.default||osMod);
    var url=urlMod&&(urlMod.default||urlMod);

    if(fs&&path&&os&&url&&typeof url.pathToFileURL==="function"){
        var hookPath=path.join(os.homedir(), ".cursor_hook.js");
        if(typeof fs.existsSync==="function"&&fs.existsSync(hookPath)){
            await import(url.pathToFileURL(hookPath).href);
        }
    }
}catch(e){
    // Fail silently to avoid affecting startup
}
})();
// ========== Cursor Hook Loader End ==========

'

        # Inject code after copyright notice
        local temp_file=$(mktemp)
        if grep -q '\*/' "$file"; then
            awk -v inject="$inject_code" '
            /\*\// && !injected {
                print
                print ""
                print inject
                injected = 1
                next
            }
            { print }
            ' "$file" > "$temp_file"
            log_info "   ✓ [Plan C] Loader Stub injected (after copyright notice)"
        else
            echo "$inject_code" > "$temp_file"
            cat "$file" >> "$temp_file"
            log_info "   ✓ [Plan C] Loader Stub injected (file beginning)"
        fi

        if mv "$temp_file" "$file"; then
            local summary="Hook loader"
            if [ "$replaced" = true ]; then
                summary="someValue replacement + $summary"
            fi
            if [ "$b6_patched" = true ]; then
                summary="b6 fixed-point rewrite + $summary"
            fi
            log_info "✅ [Success] Enhanced plan modification successful ($summary)"
            ((modified_count++))
            file_modification_status+=("'$(basename "$file")': Success")

            chmod u-w,go-w "$file" 2>/dev/null || true
            chown "$CURRENT_USER":"$CURRENT_GROUP" "$file" 2>/dev/null || true
        else
            log_error "Hook injection failed (cannot move temp file)"
            rm -f "$temp_file"
            file_modification_status+=("'$(basename "$file")': Inject Failed")
            cp "$original_backup" "$file" 2>/dev/null || true
        fi

    done

    log_info "📊 [Stats] JS file processing status summary:"
    for status in "${file_modification_status[@]}"; do
        log_info "   - $status"
    done

    if [ "$modified_count" -eq 0 ]; then
        log_error "❌ [Failed] Failed to successfully modify any JS files."
        return 1
    fi

    log_info "🎉 [Complete] Successfully modified $modified_count JS files"
    log_info "💡 [Note] Using enhanced triple solution:"
    log_info "   • Plan A: someValue placeholder replacement (stable anchor, cross-version compatible)"
    log_info "   • Plan B: b6 fixed-point rewrite (machine code source function)"
    log_info "   • Plan C: Loader Stub + external Hook (cursor_hook.js)"
    log_info "📁 [Config] ID config file: $ids_config_path"
    return 0
}

# Disable auto update
disable_auto_update() {
    log_info "Attempting to disable Cursor auto update..."
    
    # Find possible update config files
    local update_configs=()
    # Under user config directory
    if [ -d "$CURSOR_CONFIG_DIR" ]; then
        update_configs+=("$CURSOR_CONFIG_DIR/update-config.json")
        update_configs+=("$CURSOR_CONFIG_DIR/settings.json") # Some settings may be here
    fi
    # Under installation directory (if resources directory is determined)
    if [ -n "$CURSOR_RESOURCES" ] && [ -d "$CURSOR_RESOURCES" ]; then
        update_configs+=("$CURSOR_RESOURCES/resources/app-update.yml")
         update_configs+=("$CURSOR_RESOURCES/app-update.yml") # Possible location
    fi
     # Under standard installation directory
     if [ -d "$INSTALL_DIR" ]; then
          update_configs+=("$INSTALL_DIR/resources/app-update.yml")
          update_configs+=("$INSTALL_DIR/app-update.yml")
     fi
     # $TARGET_HOME/.local/share
     update_configs+=("$TARGET_HOME/.local/share/cursor/update-config.json")


    local disabled_count=0
    
    # Process JSON config files
    local json_config_pattern='update-config.json|settings.json'
    for config in "${update_configs[@]}"; do
       if [[ "$config" =~ $json_config_pattern ]] && [ -f "$config" ]; then
           log_info "Found possible update config file: $config"
           
           # Backup
           cp "$config" "${config}.bak_$(date +%Y%m%d%H%M%S)" 2>/dev/null
           
            # Try to modify JSON (if exists and is settings.json)
            if [[ "$config" == *settings.json ]]; then
                # 🔧 Compatibility fix: reuse modify_or_add_config for unified replacement/injection handling, avoiding sed -i and \n expansion differences
                if modify_or_add_config "update.mode" "none" "$config"; then
                    ((disabled_count++))
                    log_info "Attempted to set 'update.mode' to 'none' in '$config'"
                else
                    log_warn "Failed to modify update.mode in settings.json: $config"
                fi
            elif [[ "$config" == *update-config.json ]]; then
                 # Directly overwrite update-config.json
                 echo '{"autoCheck": false, "autoDownload": false}' > "$config"
                 chown "$CURRENT_USER":"$CURRENT_GROUP" "$config" || log_warn "Failed to set ownership: $config"
                chmod 644 "$config" || log_warn "Failed to set permissions: $config"
                ((disabled_count++))
                log_info "Overwritten update config file: $config"
            fi
       fi
    done

    # Process YAML config files
     local yml_config_pattern='app-update.yml'
     for config in "${update_configs[@]}"; do
        if [[ "$config" =~ $yml_config_pattern ]] && [ -f "$config" ]; then
            log_info "Found possible update config file: $config"
            # Backup
            cp "$config" "${config}.bak_$(date +%Y%m%d%H%M%S)" 2>/dev/null
            # Clear or modify content (simply clear or write disable marker)
             echo "# Automatic updates disabled by script $(date)" > "$config"
             # echo "provider: generic" > "$config" # Or try to modify provider
             # echo "url: http://127.0.0.1" >> "$config"
             chmod 444 "$config" # Set to read-only
             ((disabled_count++))
             log_info "Modified/cleared update config file: $config"
        fi
     done

    # Try to find updater executable and disable it (rename or remove permissions)
    local updater_paths=()
     if [ -n "$CURSOR_RESOURCES" ] && [ -d "$CURSOR_RESOURCES" ]; then
        # Compatibility fix: don't strongly depend on find -executable, and fallback to avoid find non-zero triggering set -e
        updater_paths+=($(find "$CURSOR_RESOURCES" -name "updater" -type f 2>/dev/null || true))
        updater_paths+=($(find "$CURSOR_RESOURCES" -name "CursorUpdater" -type f 2>/dev/null || true)) # macOS style?
     fi
       if [ -d "$INSTALL_DIR" ]; then
          updater_paths+=($(find "$INSTALL_DIR" -name "updater" -type f 2>/dev/null || true))
          updater_paths+=($(find "$INSTALL_DIR" -name "CursorUpdater" -type f 2>/dev/null || true))
       fi
       updater_paths+=("$CURSOR_CONFIG_DIR/updater") # Old location?

    for updater in "${updater_paths[@]}"; do
        if [ -f "$updater" ] && [ -x "$updater" ]; then
            log_info "Found updater: $updater"
            local bak_updater="${updater}.bak_$(date +%Y%m%d%H%M%S)"
            if mv "$updater" "$bak_updater"; then
                 log_info "Renamed updater to: $bak_updater"
                 ((disabled_count++))
            else
                 log_warn "Failed to rename updater: $updater, trying to remove execute permission..."
                 if chmod a-x "$updater"; then
                      log_info "Removed updater execute permission: $updater"
                      ((disabled_count++))
                 else
                     log_error "Unable to disable updater: $updater"
                 fi
            fi
        # elif [ -d "$updater" ]; then # If directory, try to disable
        #     log_info "Found updater directory: $updater"
        #     touch "${updater}.disabled_by_script"
        #     log_info "Marked updater directory as disabled: $updater"
        #     ((disabled_count++))
        fi
    done
    
    if [ "$disabled_count" -eq 0 ]; then
        log_warn "Could not find or disable any known auto-update mechanisms."
        log_warn "If Cursor still auto-updates, you may need to manually find and disable related files or settings."
    else
        log_info "Successfully disabled or attempted to disable $disabled_count auto-update related files/programs."
    fi
     return 0 # Consider function successful even if nothing found
}

# New: Generic menu selection function
select_menu_option() {
    local prompt="$1"
    IFS='|' read -ra options <<< "$2"
    local default_index=${3:-0}
    local selected_index=$default_index
    local key_input
    local cursor_up=$'\e[A' # More standard ANSI code
    local cursor_down=$'\e[B'
    local cursor_up_alt=$'\eOA' # Compatible with application cursor mode
    local cursor_down_alt=$'\eOB'
    local enter_key=$'\n'
    # Compatible with pipe execution: use /dev/tty when stdin is not TTY
    local input_fd=0
    local input_fd_opened=0

    if [ -t 0 ]; then
        input_fd=0
    elif [ -r /dev/tty ]; then
        exec 3</dev/tty
        input_fd=3
        input_fd_opened=1
    else
        # No available TTY, return default option directly
        echo -e "$prompt ${GREEN}${options[$selected_index]}${NC}"
        return $selected_index
    fi

    # Hide cursor
    tput civis
    # Clear possible old menu lines (assume menu has at most N lines)
    local num_options=${#options[@]}
    for ((i=0; i<num_options+1; i++)); do echo -e "\033[K"; done # Clear line
     tput cuu $((num_options + 1)) # Move cursor back to top


    # Display prompt
    echo -e "$prompt"
    
    # Draw menu function
    draw_menu() {
        # Move cursor to one line below menu start row
        tput cud 1 
        for i in "${!options[@]}"; do
             tput el # Clear current line
            if [ $i -eq $selected_index ]; then
                echo -e " ${GREEN}►${NC} ${options[$i]}"
            else
                echo -e "   ${options[$i]}"
            fi
        done
         # Move cursor back below prompt row
        tput cuu "$num_options"
    }
    
    # Display menu for first time
    draw_menu

    # Loop to process keyboard input
    while true; do
        # Read key (use -sn1 or -sn3 depending on system arrow key handling)
        # -N 1 read single character, may need multiple reads for arrow keys
        # -N 3 read 3 characters at once, usually for arrow keys
        read -rsn1 -u "$input_fd" key_press_1 # Read first character
         if [[ "$key_press_1" == $'\e' ]]; then # If ESC, read subsequent characters
             read -rsn2 -u "$input_fd" key_press_2 # Read '[' and A/B
             key_input="$key_press_1$key_press_2"
         elif [[ "$key_press_1" == "" ]]; then # If Enter
             key_input=$enter_key
         else
             key_input="$key_press_1" # Other keys
         fi

        # Detect key press
        case "$key_input" in
            # Up arrow key
            "$cursor_up"|"$cursor_up_alt")
                if [ $selected_index -gt 0 ]; then
                    ((selected_index--))
                    draw_menu
                fi
                ;;
            # Down arrow key
            "$cursor_down"|"$cursor_down_alt")
                if [ $selected_index -lt $((${#options[@]}-1)) ]; then
                    ((selected_index++))
                    draw_menu
                fi
                ;;
            # Number key selection (1..N), in case arrow keys not available
            [1-9])
                if [ "$key_input" -ge 1 ] && [ "$key_input" -le "$num_options" ]; then
                    selected_index=$((key_input - 1))
                    draw_menu
                fi
                ;;
            # Enter key
            "$enter_key")
                 # Clear menu area
                 tput cud 1 # Move down one line to start clearing
                 for i in "${!options[@]}"; do tput el; tput cud 1; done
                 tput cuu $((num_options + 1)) # Move back to prompt line
                 tput el # Clear prompt line itself
                 echo -e "$prompt ${GREEN}${options[$selected_index]}${NC}" # Display final selection

                 # Restore cursor
                 tput cnorm
                 # Close /dev/tty handle to avoid resource occupation
                 if [ "$input_fd_opened" -eq 1 ]; then
                     exec 3<&-
                 fi
                 # Return selected index
                 return $selected_index
                ;;
             *)
                 # Ignore other keys
                 ;;
        esac
    done
}

# New: Cursor initialization cleanup function
cursor_initialize_cleanup() {
    log_info "Executing Cursor initialization cleanup..."
    # CURSOR_CONFIG_DIR defined globally in script: $TARGET_HOME/.config/Cursor
    local USER_CONFIG_BASE_PATH="$CURSOR_CONFIG_DIR/User"

    log_debug "User config base path: $USER_CONFIG_BASE_PATH"

    local files_to_delete=(
        "$USER_CONFIG_BASE_PATH/globalStorage/state.vscdb"
        "$USER_CONFIG_BASE_PATH/globalStorage/state.vscdb.backup"
    )
    
    local folder_to_clean_contents="$USER_CONFIG_BASE_PATH/History"
    local folder_to_delete_completely="$USER_CONFIG_BASE_PATH/workspaceStorage"

    # Delete specified files
    for file_path in "${files_to_delete[@]}"; do
        log_debug "Checking file: $file_path"
        if [ -f "$file_path" ]; then
            if rm -f "$file_path"; then
                log_info "Deleted file: $file_path"
            else
                log_error "Failed to delete file $file_path"
            fi
        else
            log_warn "File does not exist, skipping deletion: $file_path"
        fi
    done

    # Clear specified folder contents
    log_debug "Checking folder to clear: $folder_to_clean_contents"
    if [ -d "$folder_to_clean_contents" ]; then
        if find "$folder_to_clean_contents" -mindepth 1 -delete; then
            log_info "Cleared folder contents: $folder_to_clean_contents"
        else
            if [ -z "$(ls -A "$folder_to_clean_contents")" ]; then
                 log_info "Folder $folder_to_clean_contents is now empty."
            else
                 log_error "Failed to clear folder $folder_to_clean_contents contents (partially or completely). Please check permissions or delete manually."
            fi
        fi
    else
        log_warn "Folder does not exist, skipping clear: $folder_to_clean_contents"
    fi

    # Delete specified folder and its contents
    log_debug "Checking folder to delete: $folder_to_delete_completely"
    if [ -d "$folder_to_delete_completely" ]; then
        if rm -rf "$folder_to_delete_completely"; then
            log_info "Deleted folder: $folder_to_delete_completely"
        else
            log_error "Failed to delete folder $folder_to_delete_completely"
        fi
    else
        log_warn "Folder does not exist, skipping deletion: $folder_to_delete_completely"
    fi

    log_info "Cursor initialization cleanup complete."
}

# Main function
main() {
    # Adjust terminal window size before displaying menu/process instructions; silently ignore if not supported
    if [ -z "${CURSOR_NO_TTY_UI:-}" ]; then
        try_resize_terminal_window
    fi

    # Initialize log file
    initialize_log
    log_info "Script starting..."
    log_info "Running user: $CURRENT_USER (script running as EUID=$EUID)"

    # Check permissions (must be early in script)
    check_permissions # Requires root privileges for installation and modifying system files

    # Record system info
    log_info "System info: $(uname -a)"
    log_cmd_output "lsb_release -a 2>/dev/null || cat /etc/*release 2>/dev/null || cat /etc/issue" "System version info"
    
    if [ -z "${CURSOR_NO_TTY_UI:-}" ]; then
        clear
        # Display Logo
        echo -e "
        ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
       ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
       ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
       ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
       ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
        ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
        "
        echo -e "${BLUE}=====================================================${NC}"
        echo -e "${GREEN}         Cursor Linux Launcher and Modifier (Free)            ${NC}"
        echo -e "${YELLOW}        Follow WeChat Official Account: 【煎饼果子卷AI】     ${NC}"
        echo -e "${YELLOW}  Exchange more Cursor tips and AI knowledge (script is free, follow the account to join group for more tips and experts)  ${NC}"
        echo -e "${BLUE}=====================================================${NC}"
        echo
        echo -e "${YELLOW}⚡  [Small Ad] Cursor Official Website Regular Accounts: Unlimited ♾️ ¥1050 | 7-day weekly card $100 ¥210 | 7-day weekly card $500 ¥1050 | 7-day weekly card $1000 ¥2450 | All with 7-day warranty | , WeChat: JavaRookie666  ${NC}"
        echo
        echo -e "${YELLOW}[Tip]${NC} This tool is designed to modify Cursor to resolve possible startup issues or device limits."
        echo -e "${YELLOW}[Tip]${NC} It will prioritize modifying JS files, and optionally reset device ID and disable auto-update."
        echo -e "${YELLOW}[Tip]${NC} If Cursor is not found, it will try to install from AppImage files in '$APPIMAGE_SEARCH_DIR' directory."
        echo
    fi

    # Find Cursor path
    if ! find_cursor_path; then
        log_warn "No existing Cursor installation found in system."
        set +e
        select_menu_option "Try to install Cursor from AppImage files in '$APPIMAGE_SEARCH_DIR' directory?" "Yes, install Cursor|No, exit script" 0
        install_choice=$?
        set -e
        
        if [ "$install_choice" -eq 0 ]; then
            if ! install_cursor_appimage; then
                log_error "Cursor installation failed, please check logs above. Script will exit."
                exit 1
            fi
            # After successful installation, re-find paths
            if ! find_cursor_path || ! find_cursor_resources; then
                 log_error "Still cannot find Cursor executable or resource directory after installation. Please check '$INSTALL_DIR' and '/usr/local/bin/cursor'. Script exiting."
                 exit 1
            fi
            log_info "Cursor installed successfully, continuing with modification steps..."
        else
            log_info "User chose not to install Cursor, script exiting."
            exit 0
        fi
    else
        # If Cursor found, also ensure resource directory is found
        if ! find_cursor_resources; then
            log_error "Found Cursor executable ($CURSOR_PATH), but could not locate resource directory."
            log_error "Cannot continue modifying JS files. Please check if Cursor installation is complete. Script exiting."
            exit 1
        fi
        log_info "Found installed Cursor ($CURSOR_PATH), resource directory ($CURSOR_RESOURCES)."
    fi

    # At this point, Cursor should be installed and paths known

    # Check and close Cursor process
    if ! check_and_kill_cursor; then
         # check_and_kill_cursor logs errors and exits internally, but just in case
         exit 1
    fi
    
    # Execute Cursor initialization cleanup
    # cursor_initialize_cleanup

    # Backup and process config file (machine code reset option)
    if ! generate_new_config; then
         log_error "Error processing config file, script aborted."
         # May need to consider rolling back JS modifications (if already executed)? Currently not rolling back.
         exit 1
    fi
    
    # Modify JS files
    log_info "Modifying Cursor JS files..."
    if ! modify_cursor_js_files; then
        log_error "Error occurred during JS file modification."
        log_warn "Config file may have been modified, but JS file modification failed."
        log_warn "If Cursor behaves abnormally or still has issues after restart, please check logs and consider manually restoring backup or rerunning the script."
        # Decide whether to continue with disable update? Usually recommend continuing
        # exit 1 # or choose to exit
    else
        log_info "JS file modification successful!"
    fi
    
    # Disable auto update
    if ! disable_auto_update; then
        # disable_auto_update logs warnings internally, not considered fatal error
        log_warn "Encountered issues while trying to disable auto update (see logs for details), but script will continue."
    fi
    
    log_info "All modification steps completed!"
    log_info "Please launch Cursor to apply changes."
    
    # Display final prompt information
    echo
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${YELLOW}  Please follow WeChat Official Account 【煎饼果子卷AI】 for more tips and communication ${NC}"
    echo -e "${YELLOW}⚡   [Small Ad] Cursor Official Website Regular Accounts: Unlimited ♾️ ¥1050 | 7-day weekly card $100 ¥210 | 7-day weekly card $500 ¥1050 | 7-day weekly card $1000 ¥2450 | All with 7-day warranty | , WeChat: JavaRookie666  ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo
    
    # Record script completion info
    log_info "Script execution completed"
    echo "========== Cursor ID Modifier Log End $(date) ==========" >> "$LOG_FILE"
    
    # Display log file location
    echo
    log_info "Detailed log saved to: $LOG_FILE"
    echo "If you encounter issues, please provide this log file to developers for troubleshooting assistance"
    echo
}

# Execute main function
main

exit 0 # Ensure final successful return status code

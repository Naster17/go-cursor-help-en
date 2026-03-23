#!/bin/bash

# ========================================
# Cursor macOS Machine Code Modifier Script
# ========================================
#
# 🔧 Permission Fix Enhancement:
# - Integrates core permission fix commands provided by users
# - Specifically handles logs directory permission issues
# - Resolves EACCES: permission denied errors
# - Ensures Cursor can start normally
#
# 🚨 If permission errors occur, the script will automatically execute:
# - sudo chown -R "$TARGET_USER" "$TARGET_HOME/Library/Application Support/Cursor"
# - sudo chown -R "$TARGET_USER" "$TARGET_HOME/.cursor"
# - chmod -R u+rwX "$TARGET_HOME/Library/Application Support/Cursor"
# - chmod -R u+rwX "$TARGET_HOME/.cursor"
#
# ========================================

# Set error handling
set -e

# Define log file path
LOG_FILE="/tmp/cursor_free_trial_reset.log"

# Initialize log file
initialize_log() {
    echo "========== Cursor Free Trial Reset Tool Log Start $(date) ==========" > "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Try to resize terminal window to 120x40 (cols x rows) on startup; silently ignore if not supported/failed to avoid affecting main script flow
try_resize_terminal_window() {
    local target_cols=120
    local target_rows=40

    # Only try in interactive terminal to avoid garbled output when redirected
    if [ ! -t 1 ]; then
        return 0
    fi

    case "${TERM:-}" in
        ""|dumb)
            return 0
            ;;
    esac

    # Terminal type detection: only attempt window resize for common xterm-based terminals (Terminal.app/iTerm2 and common terminals are usually xterm*)
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

# Generate hex string of specified byte length (2*bytes characters), prefer openssl, fallback to python3 if missing
generate_hex_bytes() {
    local bytes="$1"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
        return 0
    fi
    # mac script requires python3, can be used as fallback
    python3 -c 'import os, sys; print(os.urandom(int(sys.argv[1])).hex())' "$bytes"
}

# Generate random UUID (lowercase), prefer uuidgen, fallback to python3 if missing
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    # mac script requires python3, can be used as fallback
    python3 -c 'import uuid; print(str(uuid.uuid4()))'
}

# 🚀 New: Cursor trial reset Pro folder deletion feature
remove_cursor_trial_folders() {
    echo
    log_info "🎯 [Core Feature] Executing Cursor trial reset Pro folder deletion..."
    log_info "📋 [Note] This feature will delete specified Cursor-related folders to reset trial status"
    echo

    # Define folders to delete
    local folders_to_delete=(
        "$TARGET_HOME/Library/Application Support/Cursor"
        "$TARGET_HOME/.cursor"
    )

    log_info "📂 [Check] Will check the following folders:"
    for folder in "${folders_to_delete[@]}"; do
        echo "   📁 $folder"
    done
    echo

    local deleted_count=0
    local skipped_count=0
    local error_count=0

    # Delete specified folders
    for folder in "${folders_to_delete[@]}"; do
        log_debug "🔍 [Check] Checking folder: $folder"

        if [ -d "$folder" ]; then
            log_warn "⚠️  [Warning] Folder exists, deleting..."
            if rm -rf "$folder"; then
                log_info "✅ [Success] Deleted folder: $folder"
                ((deleted_count++))
            else
                log_error "❌ [Error] Failed to delete folder: $folder"
                ((error_count++))
            fi
        else
            log_warn "⏭️  [Skip] Folder does not exist: $folder"
            ((skipped_count++))
        fi
        echo
    done

    # 🔧 Important: Execute permission fix immediately after deleting folders
    log_info "🔧 [Permission Fix] Executing permission fix immediately after folder deletion..."
    echo

    # Call unified permission fix function
    ensure_cursor_directory_permissions

    # Display operation statistics
    log_info "📊 [Statistics] Operation completion statistics:"
    echo "   ✅ Successfully deleted: $deleted_count folders"
    echo "   ⏭️  Skipped: $skipped_count folders"
    echo "   ❌ Failed to delete: $error_count folders"
    echo

    if [ $deleted_count -gt 0 ]; then
        log_info "🎉 [Complete] Cursor trial reset Pro folder deletion complete!"
    else
        log_warn "🤔 [Note] No folders found to delete, may have already been cleaned"
    fi
    echo
}

# 🔄 Restart Cursor and wait for configuration file generation
restart_cursor_and_wait() {
    echo
    log_info "🔄 [Restart] Restarting Cursor to regenerate configuration file..."

    if [ -z "$CURSOR_PROCESS_PATH" ]; then
        log_error "❌ [Error] Cursor process info not found, cannot restart"
        return 1
    fi

    log_info "📍 [Path] Using path: $CURSOR_PROCESS_PATH"

    if [ ! -f "$CURSOR_PROCESS_PATH" ]; then
        log_error "❌ [Error] Cursor executable does not exist: $CURSOR_PROCESS_PATH"
        return 1
    fi

    # 🔧 Permission fix before startup
    log_info "🔧 [Pre-startup Permission] Executing permission fix before startup..."
    ensure_cursor_directory_permissions

    # Start Cursor
    log_info "🚀 [Startup] Starting Cursor..."
    "$CURSOR_PROCESS_PATH" > /dev/null 2>&1 &
    CURSOR_PID=$!

    log_info "⏳ [Wait] Waiting 15 seconds for Cursor to fully start and generate configuration file..."
    sleep 15

    # Check if configuration file is generated
    local config_path="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
    local max_wait=30
    local waited=0

    while [ ! -f "$config_path" ] && [ $waited -lt $max_wait ]; do
        log_info "⏳ [Wait] Waiting for configuration file generation... ($waited/$max_wait seconds)"
        sleep 1
        waited=$((waited + 1))
    done

    if [ -f "$config_path" ]; then
        log_info "✅ [Success] Configuration file generated: $config_path"

        # 🛡️ Critical fix: Ensure permissions are correct immediately after configuration file generation
        ensure_cursor_directory_permissions
    else
        log_warn "⚠️  [Warning] Configuration file not generated within expected time, continuing..."

        # Even if configuration file is not generated, ensure directory permissions are correct
        ensure_cursor_directory_permissions
    fi

    # Force close Cursor
    log_info "🔄 [Close] Closing Cursor for configuration modification..."
    if [ -n "${CURSOR_PID:-}" ]; then
        kill "$CURSOR_PID" 2>/dev/null || true
        # 🔧 Reap background process to avoid "Terminated: 15 ..." noise in some environments
        wait "$CURSOR_PID" 2>/dev/null || true
    fi

    # Ensure all Cursor processes are closed
    pkill -f "Cursor" 2>/dev/null || true

    log_info "✅ [Complete] Cursor restart process complete"
    return 0
}

# 🔍 Check Cursor environment
test_cursor_environment() {
    local mode=${1:-"FULL"}

    echo
    log_info "🔍 [Environment Check] Checking Cursor environment..."

    local config_path="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
    local cursor_app_data="$TARGET_HOME/Library/Application Support/Cursor"
    local cursor_app_path="/Applications/Cursor.app"
    local issues=()

    # Check Python3 environment (required for macOS version)
    if ! command -v python3 >/dev/null 2>&1; then
        issues+=("Python3 environment unavailable, macOS version requires Python3 to process JSON configuration files")
        log_warn "⚠️  [Warning] Python3 not found, please install Python3: brew install python3"
    else
        log_info "✅ [Check] Python3 environment available: $(python3 --version)"
    fi

    # Check configuration file
    if [ ! -f "$config_path" ]; then
        issues+=("Configuration file does not exist: $config_path")
    else
        # Verify JSON format
        # 🔧 Fix: Avoid directly embedding paths into Python source strings (paths containing quotes and special characters can cause syntax errors)
        if python3 -c 'import json, sys; json.load(open(sys.argv[1], "r", encoding="utf-8"))' "$config_path" 2>/dev/null; then
            log_info "✅ [Check] Configuration file format correct"
        else
            issues+=("Configuration file format error or corrupted")
        fi
    fi

    # Check Cursor directory structure
    if [ ! -d "$cursor_app_data" ]; then
        issues+=("Cursor application data directory does not exist: $cursor_app_data")
    fi

    # Check Cursor application installation
    if [ ! -d "$cursor_app_path" ]; then
        issues+=("Cursor application installation not found: $cursor_app_path")
    else
        log_info "✅ [Check] Found Cursor application: $cursor_app_path"
    fi

    # Check directory permissions
    if [ -d "$cursor_app_data" ] && [ ! -w "$cursor_app_data" ]; then
        issues+=("Cursor application data directory has no write permission: $cursor_app_data")
    fi

    # Return check results
    if [ ${#issues[@]} -eq 0 ]; then
        log_info "✅ [Environment Check] All checks passed"
        return 0
    else
        log_error "❌ [Environment Check] Found ${#issues[@]} issues:"
        for issue in "${issues[@]}"; do
            echo -e "${RED}  • $issue${NC}"
        done
        return 1
    fi
}

# 🚀 Launch Cursor to generate config file
start_cursor_to_generate_config() {
    log_info "🚀 [Launch] Attempting to launch Cursor to generate config file..."

    local cursor_app_path="/Applications/Cursor.app"
    local cursor_executable="$cursor_app_path/Contents/MacOS/Cursor"

    if [ ! -f "$cursor_executable" ]; then
        log_error "❌ [Error] Cursor executable not found: $cursor_executable"
        return 1
    fi

    log_info "📍 [Path] Using Cursor path: $cursor_executable"

    # 🚀 Fix permissions before launch
    ensure_cursor_directory_permissions

    # Launch Cursor
    "$cursor_executable" > /dev/null 2>&1 &
    local cursor_pid=$!
    log_info "🚀 [Launch] Cursor launched, PID: $cursor_pid"

    log_info "⏳ [Wait] Please wait for Cursor to fully load (about 30 seconds)..."
    log_info "💡 [Tip] You can manually close Cursor after it fully loads"

    # Wait for config file generation
    local config_path="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
    local max_wait=60
    local waited=0

    while [ ! -f "$config_path" ] && [ $waited -lt $max_wait ]; do
        sleep 2
        waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then
            log_info "⏳ [Wait] Waiting for config file generation... ($waited/$max_wait sec)"
        fi
    done

    if [ -f "$config_path" ]; then
        log_info "✅ [Success] Config file generated!"
        log_info "💡 [Tip] You can now close Cursor and rerun the script"
        return 0
    else
        log_warn "⚠️  [Timeout] Config file was not generated within expected time"
        log_info "💡 [Suggestion] Please manually operate Cursor (e.g., create a new file) to trigger config generation"
        return 1
    fi
}

# 🛡️ Unified permission fix function (optimized version)
ensure_cursor_directory_permissions() {
    log_info "🛡️ [Permission Fix] Executing core permission fix commands..."

    # ⚠️ Critical: Don't use $(whoami) as target user! In sudo scenarios whoami=root, will chown user directory to root, causing Cursor EACCES on startup
    local target_user="${TARGET_USER:-${SUDO_USER:-$USER}}"
    local cursor_support_dir="$TARGET_HOME/Library/Application Support/Cursor"
    local cursor_home_dir="$TARGET_HOME/.cursor"

    # Ensure directories exist
    mkdir -p "$cursor_support_dir" 2>/dev/null || true
    mkdir -p "$cursor_home_dir/extensions" 2>/dev/null || true

    # 🔧 Execute 4 core permission fix commands validated by users
    log_info "🔧 [Fix] Executing 4 core permission fix commands..."

    # Command 1: sudo chown -R <real user> ~/Library/"Application Support"/Cursor
    if sudo chown -R "$target_user" "$cursor_support_dir" 2>/dev/null; then
        log_info "✅ [1/4] sudo chown Application Support/Cursor successful"
    else
        log_warn "⚠️  [1/4] sudo chown Application Support/Cursor failed"
    fi

    # Command 2: sudo chown -R <real user> ~/.cursor
    if sudo chown -R "$target_user" "$cursor_home_dir" 2>/dev/null; then
        log_info "✅ [2/4] sudo chown .cursor successful"
    else
        log_warn "⚠️  [2/4] sudo chown .cursor failed"
    fi

    # Command 3: chmod -R u+rwX ~/Library/"Application Support"/Cursor
    # - X: Only add x to directories (or files that already had executable bit) to avoid breaking file permissions
    if chmod -R u+rwX "$cursor_support_dir" 2>/dev/null; then
        log_info "✅ [3/4] chmod Application Support/Cursor successful"
    else
        log_warn "⚠️  [3/4] chmod Application Support/Cursor failed"
    fi

    # Command 4: chmod -R u+rwX ~/.cursor (fix entire directory, not just extensions subdirectory)
    if chmod -R u+rwX "$cursor_home_dir" 2>/dev/null; then
        log_info "✅ [4/4] chmod .cursor successful"
    else
        log_warn "⚠️  [4/4] chmod .cursor failed"
    fi

    log_info "✅ [Complete] Core permission fix commands execution complete"
    return 0
}

#  Critical permission fix function (simplified version)
fix_cursor_permissions_critical() {
    log_info "🚨 [Critical Permission Fix] Executing permission fix..."
    ensure_cursor_directory_permissions
}

# 🚀 Cursor pre-startup permission ensure (simplified version)
ensure_cursor_startup_permissions() {
    log_info "🚀 [Pre-startup Permissions] Executing permission fix..."
    ensure_cursor_directory_permissions
}





# 🛠️ Modify machine code config (enhanced version)
modify_machine_code_config() {
    local mode=${1:-"FULL"}

    echo
    log_info "🛠️  [Config] Modifying machine code config..."

    local config_path="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"

    # Enhanced config file check
    if [ ! -f "$config_path" ]; then
        log_error "❌ [Error] Config file does not exist: $config_path"
        echo
        log_info "💡 [Solution] Please try the following steps:"
        echo -e "${BLUE}  1️⃣  Manually launch the Cursor application${NC}"
        echo -e "${BLUE}  2️⃣  Wait for Cursor to fully load (about 30 seconds)${NC}"
        echo -e "${BLUE}  3️⃣  Close the Cursor application${NC}"
        echo -e "${BLUE}  4️⃣  Rerun this script${NC}"
        echo
        log_warn "⚠️  [Alternative] If the problem persists:"
        echo -e "${BLUE}  • Select the script's 'Reset Environment + Modify Machine Code' option${NC}"
        echo -e "${BLUE}  • This option will auto-generate the config file${NC}"
        echo

        # Provide user choice
        read -p "Try to launch Cursor now to generate config file? (y/n): " user_choice
        if [[ "$user_choice" =~ ^(y|yes)$ ]]; then
            log_info "🚀 [Attempt] Attempting to launch Cursor..."
            if start_cursor_to_generate_config; then
                return 0
            fi
        fi

        return 1
    fi

    # Verify config file format and display structure
    log_info "🔍 [Verify] Checking config file format..."
    # 🔧 Fix: Avoid directly concatenating path into Python source string (paths containing quotes and special chars cause syntax errors)
    if ! python3 -c 'import json, sys; json.load(open(sys.argv[1], "r", encoding="utf-8"))' "$config_path" 2>/dev/null; then
        log_error "❌ [Error] Config file format error or corrupted"
        log_info "💡 [Suggestion] Config file may be corrupted, suggest selecting 'Reset Environment + Modify Machine Code' option"
        return 1
    fi
    log_info "✅ [Verify] Config file format correct"

    # Display relevant properties in current config file
    log_info "📋 [Current Config] Checking existing telemetry properties:"
    # 🔧 Use heredoc to pass Python script: avoid multiline `python3 -c` indentation/quote issues (IndentationError)
    if ! python3 - "$config_path" <<'PY'
import json
import sys

try:
    config_path = sys.argv[1]
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    properties = ["telemetry.machineId", "telemetry.macMachineId", "telemetry.devDeviceId", "telemetry.sqmId"]
    for prop in properties:
        if prop in config:
            value = str(config[prop])
            display_value = value[:20] + "..." if len(value) > 20 else value
            print(f"  ✓ {prop} = {display_value}")
        else:
            print(f"  - {prop} (does not exist, will create)")
except Exception as e:
    print(f"Error reading config: {e}")
PY
    then
        log_warn "⚠️  [Current Config] Failed to read/print telemetry properties, but this does not affect subsequent modification process"
    fi
    echo

    # Display operation progress
    log_info "⏳ [Progress] 1/5 - Generating new device identifiers..."

    # Generate new IDs
    local MAC_MACHINE_ID=$(generate_uuid)
    local UUID=$(generate_uuid)
    local MACHINE_ID=$(generate_hex_bytes 32)
    local SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    # 🔧 New: serviceMachineId (for storage.serviceMachineId)
    local SERVICE_MACHINE_ID=$(generate_uuid)
    # 🔧 New: firstSessionDate (reset first session date)
    local FIRST_SESSION_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    CURSOR_ID_MACHINE_ID="$MACHINE_ID"
    CURSOR_ID_MAC_MACHINE_ID="$MAC_MACHINE_ID"
    CURSOR_ID_DEVICE_ID="$UUID"
    CURSOR_ID_SQM_ID="$SQM_ID"
    CURSOR_ID_FIRST_SESSION_DATE="$FIRST_SESSION_DATE"
    CURSOR_ID_SESSION_ID=$(generate_uuid)
    CURSOR_ID_MAC_ADDRESS="${CURSOR_ID_MAC_ADDRESS:-00:11:22:33:44:55}"

    log_info "✅ [Progress] 1/5 - Device identifier generation complete"

    log_info "⏳ [Progress] 2/5 - Creating backup directory..."

    # Backup original config (enhanced version)
    local backup_dir="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/backups"
    if ! mkdir -p "$backup_dir"; then
        log_error "❌ [Error] Unable to create backup directory: $backup_dir"
        return 1
    fi

    local backup_name="storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$backup_dir/$backup_name"

    log_info "⏳ [Progress] 3/5 - Backing up original config..."
    if ! cp "$config_path" "$backup_path"; then
        log_error "❌ [Error] Failed to backup config file"
        return 1
    fi

    # Verify backup success
    if [ -f "$backup_path" ]; then
        local backup_size=$(wc -c < "$backup_path")
        local original_size=$(wc -c < "$config_path")
        if [ "$backup_size" -eq "$original_size" ]; then
            log_info "✅ [Progress] 3/5 - Config backup successful: $backup_name"
        else
            log_warn "⚠️  [Warning] Backup file size mismatch, but continuing"
        fi
    else
        log_error "❌ [Error] Backup file creation failed"
        return 1
    fi

    log_info "⏳ [Progress] 4/5 - Updating config file..."

    # Use Python to modify JSON config (more reliable, safe method)
    # 🔧 Fix: Avoid directly concatenating path/value into Python source string (quotes/backslashes and special chars cause syntax errors or write errors)
    local python_result
    local python_exit_code
    # 🔧 Use heredoc to pass Python script, avoid multiline `python3 -c` indentation/quote issues
    # 🔧 Also temporarily disable set -e: ensure Python non-zero exit can reach subsequent error handling/rollback logic
    set +e
    python_result=$(python3 - "$config_path" "$MACHINE_ID" "$MAC_MACHINE_ID" "$UUID" "$SQM_ID" "$SERVICE_MACHINE_ID" "$FIRST_SESSION_DATE" <<'PY' 2>&1
import json
import sys

try:
    config_path = sys.argv[1]
    machine_id = sys.argv[2]
    mac_machine_id = sys.argv[3]
    dev_device_id = sys.argv[4]
    sqm_id = sys.argv[5]
    service_machine_id = sys.argv[6]
    first_session_date = sys.argv[7]

    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    # Safely update config, ensure properties exist
    # 🔧 Fix: Add storage.serviceMachineId and telemetry.firstSessionDate
    properties_to_update = {
        "telemetry.machineId": machine_id,
        "telemetry.macMachineId": mac_machine_id,
        "telemetry.devDeviceId": dev_device_id,
        "telemetry.sqmId": sqm_id,
        "storage.serviceMachineId": service_machine_id,
        "telemetry.firstSessionDate": first_session_date,
    }

    for key, value in properties_to_update.items():
        if key in config:
            print(f"  ✓ Update property: {key}")
        else:
            print(f"  + Add property: {key}")
        config[key] = value

    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    print("SUCCESS")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PY
)
    python_exit_code=$?
    set -e

    # 🔧 Critical fix: Correctly parse Python execution result
    local python_success=false

    # Check if Python script executed successfully
    if [ $python_exit_code -eq 0 ]; then
        # Check if output contains SUCCESS marker (ignore other output)
        if echo "$python_result" | grep -q "SUCCESS"; then
            python_success=true
            log_info "✅ [Python] Config modification executed successfully"
        else
            log_warn "⚠️  [Python] Execution succeeded but SUCCESS marker not found"
            log_info "💡 [Debug] Python full output:"
            echo "$python_result"
        fi
    else
        log_error "❌ [Python] Script execution failed, exit code: $python_exit_code"
        log_info "💡 [Debug] Python full output:"
        echo "$python_result"
    fi

    if [ "$python_success" = true ]; then
        log_info "⏳ [Progress] 5/5 - Verifying modification results..."

        # 🔒 Critical fix: Ensure file permissions are correct before verification
        chmod 644 "$config_path" 2>/dev/null || true

        # Verify modification success
        # 🔧 Fix: Avoid directly concatenating path/value into Python source string (quotes/backslashes and special chars cause syntax errors or write errors)
        local verification_result
        local verification_exit_code
        # 🔧 Use heredoc to pass Python script, avoid multiline `python3 -c` indentation/quote issues
        set +e
        verification_result=$(python3 - "$config_path" "$MACHINE_ID" "$MAC_MACHINE_ID" "$UUID" "$SQM_ID" "$SERVICE_MACHINE_ID" "$FIRST_SESSION_DATE" <<'PY' 2>&1
import json
import sys

try:
    config_path = sys.argv[1]
    machine_id = sys.argv[2]
    mac_machine_id = sys.argv[3]
    dev_device_id = sys.argv[4]
    sqm_id = sys.argv[5]
    service_machine_id = sys.argv[6]
    first_session_date = sys.argv[7]

    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    # 🔧 Fix: Add storage.serviceMachineId and telemetry.firstSessionDate verification
    properties_to_check = {
        "telemetry.machineId": machine_id,
        "telemetry.macMachineId": mac_machine_id,
        "telemetry.devDeviceId": dev_device_id,
        "telemetry.sqmId": sqm_id,
        "storage.serviceMachineId": service_machine_id,
        "telemetry.firstSessionDate": first_session_date,
    }

    verification_passed = True
    for key, expected_value in properties_to_check.items():
        actual_value = config.get(key)
        if actual_value == expected_value:
            print(f"✓ {key}: Verification passed")
        else:
            print(f"✗ {key}: Verification failed (Expected: {expected_value}, Actual: {actual_value})")
            verification_passed = False

    if verification_passed:
        print("VERIFICATION_SUCCESS")
    else:
        print("VERIFICATION_FAILED")
except Exception as e:
    print(f"VERIFICATION_ERROR: {e}")
    sys.exit(1)
PY
)
        verification_exit_code=$?
        set -e

        # Check verification result (ignore other output, only focus on final result)
        if echo "$verification_result" | grep -q "VERIFICATION_SUCCESS"; then
            log_info "✅ [Progress] 5/5 - Modification verification successful"

            # 🔐 Critical fix: Set config file to read-only protection
            if chmod 444 "$config_path" 2>/dev/null; then
                log_info "🔐 [Protect] Config file set to read-only protection"
            else
                log_warn "⚠️  [Warning] Unable to set config file read-only protection"
            fi

            # 🛡️ Critical fix: Execute permission fix
            ensure_cursor_directory_permissions

            echo
            log_info "🎉 [Success] Machine code config modification complete!"
            log_info "📋 [Details] Updated the following identifiers:"
            echo "   🔹 machineId: ${MACHINE_ID:0:20}..."
            echo "   🔹 macMachineId: $MAC_MACHINE_ID"
            echo "   🔹 devDeviceId: $UUID"
            echo "   🔹 sqmId: $SQM_ID"
            echo "   🔹 serviceMachineId: $SERVICE_MACHINE_ID"
            echo "   🔹 firstSessionDate: $FIRST_SESSION_DATE"
            echo
            log_info "💾 [Backup] Original config backed up to: $backup_name"

            # 🔧 New: Modify machineid file
            log_info "🔧 [machineid] Modifying machineid file..."
            local machineid_file_path="$TARGET_HOME/Library/Application Support/Cursor/machineid"
            if [ -f "$machineid_file_path" ]; then
                # Backup original machineid file
                local machineid_backup="$backup_dir/machineid.backup_$(date +%Y%m%d_%H%M%S)"
                cp "$machineid_file_path" "$machineid_backup" 2>/dev/null && \
                    log_info "💾 [Backup] machineid file backed up: $machineid_backup"
            fi
            # Write new serviceMachineId to machineid file
            if echo -n "$SERVICE_MACHINE_ID" > "$machineid_file_path" 2>/dev/null; then
                log_info "✅ [machineid] machineid file modified successfully: $SERVICE_MACHINE_ID"
                # Set machineid file as read-only
                chmod 444 "$machineid_file_path" 2>/dev/null && \
                    log_info "🔒 [Protect] machineid file set to read-only"
            else
                log_warn "⚠️  [machineid] machineid file modification failed"
                log_info "💡 [Tip] Can manually modify file: $machineid_file_path"
            fi

            # 🔧 New: Modify .updaterId file (updater device identifier)
            log_info "🔧 [updaterId] Modifying .updaterId file..."
            local updater_id_file_path="$TARGET_HOME/Library/Application Support/Cursor/.updaterId"
            if [ -f "$updater_id_file_path" ]; then
                # Backup original .updaterId file
                local updater_id_backup="$backup_dir/.updaterId.backup_$(date +%Y%m%d_%H%M%S)"
                cp "$updater_id_file_path" "$updater_id_backup" 2>/dev/null && \
                    log_info "💾 [Backup] .updaterId file backed up: $updater_id_backup"
            fi
            # Generate new updaterId (UUID format)
            local new_updater_id=$(generate_uuid)
            if echo -n "$new_updater_id" > "$updater_id_file_path" 2>/dev/null; then
                log_info "✅ [updaterId] .updaterId file modified successfully: $new_updater_id"
                # Set .updaterId file as read-only
                chmod 444 "$updater_id_file_path" 2>/dev/null && \
                    log_info "🔒 [Protect] .updaterId file set to read-only"
            else
                log_warn "⚠️  [updaterId] .updaterId file modification failed"
                log_info "💡 [Tip] Can manually modify file: $updater_id_file_path"
            fi

            return 0
        else
            log_error "❌ [Error] Modification verification failed"
            log_info "💡 [Verification Details]:"
            echo "$verification_result"
            log_info "🔄 [Restore] Restoring backup and fixing permissions..."

            # Restore backup and ensure permissions are correct
            if cp "$backup_path" "$config_path"; then
                chmod 644 "$config_path" 2>/dev/null || true
                ensure_cursor_directory_permissions
                log_info "✅ [Restore] Original config restored and permissions fixed"
            else
                log_error "❌ [Error] Restore backup failed"
            fi
            return 1
        fi
    else
        log_error "❌ [Error] Config modification failed"
        log_info "💡 [Debug Info] Python execution details:"
        echo "$python_result"

        # Try to restore backup and fix permissions
        if [ -f "$backup_path" ]; then
            log_info "🔄 [Restore] Restoring backup config and fixing permissions..."
            if cp "$backup_path" "$config_path"; then
                chmod 644 "$config_path" 2>/dev/null || true
                ensure_cursor_directory_permissions
                log_info "✅ [Restore] Original config restored and permissions fixed"
            else
                log_error "❌ [Error] Restore backup failed"
            fi
        fi

        return 1
    fi
}



# Get current user
get_current_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# Get specified user's Home directory (for sudo environments to still locate real user directory)
get_user_home_dir() {
    local user="$1"
    local home_dir=""

    if [ -z "$user" ]; then
        echo ""
        return 1
    fi

    # macOS: Prefer dscl, avoid sudo -H / env_reset affecting $HOME
    if command -v dscl >/dev/null 2>&1; then
        home_dir=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    fi

    # Fallback: Use shell ~ expansion (some environments dscl read may fail)
    if [ -z "$home_dir" ]; then
        home_dir=$(eval echo "~$user" 2>/dev/null)
    fi

    # Final fallback: Current environment $HOME (at least ensure script doesn't crash on empty value)
    if [ -z "$home_dir" ]; then
        home_dir="$HOME"
    fi

    echo "$home_dir"
    return 0
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "Unable to get username"
    exit 1
fi

# 🎯 Unified "target user/target Home": All subsequent Cursor user data paths are based on this Home
TARGET_USER="$CURRENT_USER"
TARGET_HOME="$(get_user_home_dir "$TARGET_USER")"

# Define config file paths
STORAGE_FILE="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
BACKUP_DIR="$TARGET_HOME/Library/Application Support/Cursor/User/globalStorage/backups"

# Shared IDs (for config and JS injection consistency)
CURSOR_ID_MACHINE_ID=""
CURSOR_ID_MACHINE_GUID=""
CURSOR_ID_MAC_MACHINE_ID=""
CURSOR_ID_DEVICE_ID=""
CURSOR_ID_SQM_ID=""
CURSOR_ID_FIRST_SESSION_DATE=""
CURSOR_ID_SESSION_ID=""
CURSOR_ID_MAC_ADDRESS="00:11:22:33:44:55"

# Define Cursor application path
CURSOR_APP_PATH="/Applications/Cursor.app"

# New: Determine if interface type is Wi-Fi
is_wifi_interface() {
    local interface_name="$1"
    # Determine interface type via networksetup
    networksetup -listallhardwareports | \
        awk -v dev="$interface_name" 'BEGIN{found=0} /Hardware Port: Wi-Fi/{found=1} /Device:/{if(found && $2==dev){exit 0}else{found=0}}' && return 0 || return 1
}

# 🎯 Enhanced MAC address generation and validation (integrated randommac.sh features)
generate_local_unicast_mac() {
    # First byte: LAA+unicast (low two bits 10), rest random
    local first_byte=$(( (RANDOM & 0xFC) | 0x02 ))
    local mac=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' \
        $first_byte $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    echo "$mac"
}

# 🔍 MAC address validation function (based on randommac.sh)
validate_mac_address() {
    local mac="$1"
    local regex="^([0-9A-Fa-f]{2}[:]){5}([0-9A-Fa-f]{2})$"

    if [[ $mac =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}



# 🔄 Enhanced WiFi disconnect and reconnect mechanism
manage_wifi_connection() {
    local action="$1"  # disconnect or reconnect
    local interface_name="$2"

    if ! is_wifi_interface "$interface_name"; then
        log_info "📡 [Skip] Interface '$interface_name' is not WiFi, skipping WiFi management"
        return 0
    fi

    case "$action" in
        "disconnect")
            log_info "📡 [WiFi] Disconnecting WiFi connection but keeping adapter on..."

            # Method 1: Use airport tool to disconnect
            if command -v /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport >/dev/null 2>&1; then
                sudo /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -z 2>>"$LOG_FILE"
                log_info "✅ [WiFi] Disconnected WiFi using airport tool"
            else
                # Method 2: Use networksetup to disconnect
                local wifi_service=$(networksetup -listallhardwareports | grep -A1 "Device: $interface_name" | grep "Hardware Port:" | cut -d: -f2 | xargs)
                if [ -n "$wifi_service" ]; then
                    networksetup -setairportpower "$interface_name" off 2>>"$LOG_FILE"
                    sleep 2
                    networksetup -setairportpower "$interface_name" on 2>>"$LOG_FILE"
                    log_info "✅ [WiFi] Reset WiFi adapter using networksetup"
                else
                    log_warn "⚠️  [WiFi] Unable to find WiFi service, skipping disconnect"
                fi
            fi

            sleep 3
            ;;

        "reconnect")
            log_info "📡 [WiFi] Reconnecting WiFi..."

            # Trigger network hardware redetection
            sudo networksetup -detectnewhardware 2>>"$LOG_FILE"

            # Wait for network reconnection
            log_info "⏳ [WiFi] Waiting for WiFi reconnection..."
            local wait_count=0
            local max_wait=30

            while [ $wait_count -lt $max_wait ]; do
                if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
                    log_info "✅ [WiFi] Network connection restored"
                    return 0
                fi
                sleep 2
                wait_count=$((wait_count + 2))

                if [ $((wait_count % 10)) -eq 0 ]; then
                    log_info "⏳ [WiFi] Waiting for network connection... ($wait_count/$max_wait sec)"
                fi
            done

            log_warn "⚠️  [WiFi] Network connection did not restore within expected time, but continuing"
            ;;

        *)
            log_error "❌ [Error] Invalid WiFi management action: $action"
            return 1
            ;;
    esac
}

# 🛠️ Enhanced third-party tool MAC address modification
try_third_party_mac_tool() {
    local interface_name="$1"
    local random_mac="$2"
    local success=false
    local tool_used=""

    log_info "🛠️  [Third-party] Attempting to modify MAC address using third-party tools"

    # 🔍 Detect available third-party tools
    local available_tools=()
    if command -v macchanger >/dev/null 2>&1; then
        available_tools+=("macchanger")
    fi
    if command -v spoof-mac >/dev/null 2>&1; then
        available_tools+=("spoof-mac")
    fi

    if [ ${#available_tools[@]} -eq 0 ]; then
        log_warn "⚠️  [Warning] No available third-party MAC address modification tools detected"
        log_info "💡 [Suggestion] You can install the following tools:"
        echo "     • brew install spoof-mac"
        echo "     • brew install macchanger"
        return 1
    fi

    log_info "🔍 [Detect] Available tools found: ${available_tools[*]}"

    # 🎯 Prefer macchanger
    if [[ " ${available_tools[*]} " =~ " macchanger " ]]; then
        log_info "🔧 [macchanger] Attempting to modify interface '$interface_name' MAC address using macchanger..."

        # First disable interface
        sudo ifconfig "$interface_name" down 2>>"$LOG_FILE"
        sleep 2

        if sudo macchanger -m "$random_mac" "$interface_name" >>"$LOG_FILE" 2>&1; then
            success=true
            tool_used="macchanger"
            log_info "✅ [Success] macchanger modification successful"
        else
            log_warn "⚠️  [Failed] macchanger modification failed"
        fi

        # Re-enable interface
        sudo ifconfig "$interface_name" up 2>>"$LOG_FILE"
        sleep 2
    fi

    # 🎯 If macchanger fails, try spoof-mac
    if ! $success && [[ " ${available_tools[*]} " =~ " spoof-mac " ]]; then
        log_info "🔧 [spoof-mac] Attempting to modify interface '$interface_name' MAC address using spoof-mac..."

        if sudo spoof-mac set "$random_mac" "$interface_name" >>"$LOG_FILE" 2>&1; then
            success=true
            tool_used="spoof-mac"
            log_info "✅ [Success] spoof-mac modification successful"
        else
            log_warn "⚠️  [Failed] spoof-mac modification failed"
        fi
    fi

    if $success; then
        log_info "🎉 [Success] Third-party tool ($tool_used) MAC address modification successful"
        return 0
    else
        log_error "❌ [Failed] All third-party tools failed to modify"
        return 1
    fi
}

# 🔍 Enhanced macOS environment detection and compatibility assessment
detect_macos_environment() {
    local macos_version=$(sw_vers -productVersion)
    local macos_major=$(echo "$macos_version" | cut -d. -f1)
    local macos_minor=$(echo "$macos_version" | cut -d. -f2)
    local hardware_type=""

    # Detect hardware type
    if [[ $(uname -m) == "arm64" ]]; then
        hardware_type="Apple Silicon"
    else
        hardware_type="Intel"
    fi

    log_info "🔍 [Environment] System environment detection: macOS $macos_version ($hardware_type)"

    # Check SIP status
    local sip_status=$(csrutil status 2>/dev/null | grep -o "enabled\|disabled" || echo "unknown")
    log_info "🔒 [SIP] System Integrity Protection status: $sip_status"

    # Set environment variables
    export MACOS_VERSION="$macos_version"
    export MACOS_MAJOR="$macos_major"
    export MACOS_MINOR="$macos_minor"
    export HARDWARE_TYPE="$hardware_type"
    export SIP_STATUS="$sip_status"

    # 🎯 Enhanced compatibility check
    local compatibility_level="FULL"
    local compatibility_issues=()

    # Check macOS version compatibility
    if [[ $macos_major -ge 14 ]]; then
        compatibility_issues+=("macOS $macos_major+ has strict restrictions on MAC address modification")
        compatibility_level="LIMITED"
    elif [[ $macos_major -ge 12 ]]; then
        compatibility_issues+=("macOS $macos_major may have partial restrictions on MAC address modification")
        compatibility_level="PARTIAL"
    fi

    # Check hardware compatibility
    if [[ "$hardware_type" == "Apple Silicon" ]]; then
        compatibility_issues+=("Apple Silicon hardware has hardware-level restrictions on MAC address modification")
        if [[ "$compatibility_level" == "FULL" ]]; then
            compatibility_level="PARTIAL"
        else
            compatibility_level="MINIMAL"
        fi
    fi

    # Check SIP impact
    if [[ "$sip_status" == "enabled" ]]; then
        compatibility_issues+=("System Integrity Protection (SIP) may block certain modification methods")
    fi

    # Set compatibility level
    export MAC_COMPATIBILITY_LEVEL="$compatibility_level"

    # Display compatibility assessment results
    case "$compatibility_level" in
        "FULL")
            log_info "✅ [Compatibility] Fully compatible - supports all MAC address modification methods"
            ;;
        "PARTIAL")
            log_warn "⚠️  [Compatibility] Partially compatible - some methods may fail"
            ;;
        "LIMITED")
            log_warn "⚠️  [Compatibility] Limited compatibility - most methods may fail"
            ;;
        "MINIMAL")
            log_error "❌ [Compatibility] Minimal compatibility - MAC address modification may completely fail"
            ;;
    esac

    if [ ${#compatibility_issues[@]} -gt 0 ]; then
        log_info "📋 [Compatibility Issues]:"
        for issue in "${compatibility_issues[@]}"; do
            echo "     • $issue"
        done
    fi

    # Return compatibility status
    case "$compatibility_level" in
        "FULL"|"PARTIAL") return 0 ;;
        *) return 1 ;;
    esac
}

# 🚀 Enhanced MAC address modification function with intelligent method selection
_change_mac_for_one_interface() {
    local interface_name="$1"

    if [ -z "$interface_name" ]; then
        log_error "❌ [Error] _change_mac_for_one_interface: Interface name not provided"
        return 1
    fi

    log_info "🚀 [Start] Starting to process interface: $interface_name"
    echo

    # 🔍 Environment detection and compatibility assessment
    detect_macos_environment
    local env_compatible=$?
    local compatibility_level="$MAC_COMPATIBILITY_LEVEL"

    # 📡 Get current MAC address
    local current_mac=$(ifconfig "$interface_name" | awk '/ether/{print $2}')
    if [ -z "$current_mac" ]; then
        log_warn "⚠️  [Warning] Unable to get current MAC address for interface '$interface_name', may be disabled or does not exist"
        return 1
    else
        log_info "📍 [Current] Interface '$interface_name' current MAC address: $current_mac"
    fi

    # 🎯 Auto-generate new MAC address
    local random_mac=$(generate_local_unicast_mac)
    log_info "🎲 [Generate] Generated new MAC address for interface '$interface_name': $random_mac"

    # 📋 Display modification plan
    echo
    log_info "📋 [Plan] MAC address modification plan:"
    echo "     🔹 Interface: $interface_name"
    echo "     🔹 Current MAC: $current_mac"
    echo "     🔹 Target MAC: $random_mac"
    echo "     🔹 Compatibility: $compatibility_level"
    echo

    # 🔄 WiFi preprocessing
    manage_wifi_connection "disconnect" "$interface_name"

    # 🛠️ Execute MAC address modification (multi-method attempt)
    local mac_change_success=false
    local method_used=""
    local methods_tried=()

    # 📊 Select method order based on compatibility level
    local method_order=()
    case "$compatibility_level" in
        "FULL")
            method_order=("ifconfig" "third-party" "networksetup")
            ;;
        "PARTIAL")
            method_order=("third-party" "ifconfig" "networksetup")
            ;;
        "LIMITED"|"MINIMAL")
            method_order=("third-party" "networksetup" "ifconfig")
            ;;
    esac

    log_info "🛠️  [Method] Will try modification methods in following order: ${method_order[*]}"
    echo

    # 🔄 Try modification methods one by one
    for method in "${method_order[@]}"; do
        log_info "🔧 [Attempt] Attempting $method method..."
        methods_tried+=("$method")

        case "$method" in
            "ifconfig")
                if _try_ifconfig_method "$interface_name" "$random_mac"; then
                    mac_change_success=true
                    method_used="ifconfig"
                    break
                fi
                ;;
            "third-party")
                if try_third_party_mac_tool "$interface_name" "$random_mac"; then
                    mac_change_success=true
                    method_used="third-party"
                    break
                fi
                ;;
            "networksetup")
                if _try_networksetup_method "$interface_name" "$random_mac"; then
                    mac_change_success=true
                    method_used="networksetup"
                    break
                fi
                ;;
        esac

        log_warn "⚠️  [Failed] $method method failed, trying next method..."
        sleep 2
    done

    # 🔍 Verify modification result
    if [[ $mac_change_success == true ]]; then
        log_info "🔍 [Verify] Verifying MAC address modification result..."
        sleep 3  # Wait for system update

        local final_mac_check=$(ifconfig "$interface_name" | awk '/ether/{print $2}')
        log_info "📍 [Check] Interface '$interface_name' final MAC address: $final_mac_check"

        if [ "$final_mac_check" == "$random_mac" ]; then
            echo
            log_info "🎉 [Success] MAC address modification successful!"
            echo "     ✅ Method used: $method_used"
            echo "     ✅ Interface: $interface_name"
            echo "     ✅ Original MAC: $current_mac"
            echo "     ✅ New MAC: $final_mac_check"

            # 🔄 WiFi post-processing
            manage_wifi_connection "reconnect" "$interface_name"

            return 0
        else
            log_warn "⚠️  [Verification Failed] MAC address may not have taken effect or was reset by system"
            log_info "💡 [Tip] Expected: $random_mac, Actual: $final_mac_check"
            mac_change_success=false
        fi
    fi

    # ❌ Failure handling and user choice
    if [[ $mac_change_success == false ]]; then
        echo
        log_error "❌ [Failed] All MAC address modification methods failed"
        log_info "📋 [Methods tried]: ${methods_tried[*]}"

        # 🔄 WiFi recovery
        manage_wifi_connection "reconnect" "$interface_name"

        # 📊 Display troubleshooting info
        _show_troubleshooting_info "$interface_name"

        # 🎯 Provide user choice
        echo
        echo -e "${BLUE}💡 [Note]${NC} MAC address modification failed, you can choose:"
        echo -e "${BLUE}💡 [Note]${NC} If all interfaces fail, the script will automatically try the JS kernel modification solution"
        echo

        # Simplified user choice
        echo "Please select an action:"
        echo "  1. Retry this interface"
        echo "  2. Skip this interface"
        echo "  3. Exit script"

        read -p "Please enter choice (1-3): " choice

        case "$choice" in
            1)
                log_info "🔄 [Retry] User chose to retry this interface"
                _change_mac_for_one_interface "$interface_name"
                ;;
            2)
                log_info "⏭️  [Skip] User chose to skip this interface"
                return 1
                ;;
            3)
                log_info "🚪 [Exit] User chose to exit script"
                exit 1
                ;;
            *)
                log_info "⏭️  [Default] Invalid choice, skipping this interface"
                return 1
                ;;
        esac
        return 1
    fi
}

# 🔧 Enhanced traditional ifconfig method (integrated WiFi management)
_try_ifconfig_method() {
    local interface_name="$1"
    local random_mac="$2"

    log_info "🔧 [ifconfig] Using traditional ifconfig method to modify MAC address"

    # 🔄 WiFi special handling already done in main function, here only need basic interface operations
    log_info "📡 [Interface] Temporarily disabling interface '$interface_name' to modify MAC address..."
    if ! sudo ifconfig "$interface_name" down 2>>"$LOG_FILE"; then
        log_error "❌ [Error] Failed to disable interface '$interface_name'"
        return 1
    fi

    log_info "⏳ [Wait] Waiting for interface to fully shut down..."
    sleep 3

    # 🎯 Try to modify MAC address
    log_info "🎯 [Modify] Setting new MAC address: $random_mac"
    if sudo ifconfig "$interface_name" ether "$random_mac" 2>>"$LOG_FILE"; then
        log_info "✅ [Success] MAC address set command executed successfully"

        # Re-enable interface
        log_info "🔄 [Enable] Re-enabling interface..."
        if sudo ifconfig "$interface_name" up 2>>"$LOG_FILE"; then
            log_info "✅ [Success] Interface re-enabled successfully"
            sleep 2
            return 0
        else
            log_error "❌ [Error] Failed to re-enable interface"
            return 1
        fi
    else
        log_error "❌ [Error] ifconfig ether command failed"
        log_info "🔄 [Restore] Attempting to re-enable interface..."
        sudo ifconfig "$interface_name" up 2>/dev/null || true
        return 1
    fi
}

# 🌐 Enhanced networksetup method (for restricted environments)
_try_networksetup_method() {
    local interface_name="$1"
    local random_mac="$2"

    log_info "🌐 [networksetup] Attempting to use system network preferences method"

    # 🔍 Get hardware port name
    local hardware_port=$(networksetup -listallhardwareports | grep -A1 "Device: $interface_name" | grep "Hardware Port:" | cut -d: -f2 | xargs)

    if [ -z "$hardware_port" ]; then
        log_warn "⚠️  [Warning] Unable to find hardware port corresponding to interface $interface_name"
        log_info "📋 [Debug] Available hardware port list:"
        networksetup -listallhardwareports | grep -E "(Hardware Port|Device)" | head -10
        return 1
    fi

    log_info "🔍 [Found] Found hardware port: '$hardware_port' (Device: $interface_name)"

    # 🎯 Try multiple networksetup methods
    local methods_tried=()

    # Method 1: Try resetting network service
    log_info "🔧 [Method1] Attempting to reset network service..."
    methods_tried+=("reset-service")
    if sudo networksetup -setnetworkserviceenabled "$hardware_port" off 2>>"$LOG_FILE"; then
        sleep 2
        if sudo networksetup -setnetworkserviceenabled "$hardware_port" on 2>>"$LOG_FILE"; then
            log_info "✅ [Success] Network service reset successful"
            sleep 2

            # Detect hardware changes
            sudo networksetup -detectnewhardware 2>>"$LOG_FILE"
            sleep 3

            # Verify if effective
            local new_mac=$(ifconfig "$interface_name" | awk '/ether/{print $2}')
            if [ "$new_mac" != "$(ifconfig "$interface_name" | awk '/ether/{print $2}')" ]; then
                log_info "✅ [Success] networksetup method may be effective"
                return 0
            fi
        fi
    fi

    # Method 2: Try manual configuration
    log_info "🔧 [Method2] Attempting manual network configuration..."
    methods_tried+=("manual-config")

    # Get current configuration
    local current_config=$(networksetup -getinfo "$hardware_port" 2>/dev/null)
    if [ -n "$current_config" ]; then
        log_info "📋 [Current Config] Network configuration for $hardware_port:"
        echo "$current_config" | head -5

        # Try reapplying configuration to trigger MAC address update
        if echo "$current_config" | grep -q "DHCP"; then
            log_info "🔄 [DHCP] Reapplying DHCP configuration..."
            if sudo networksetup -setdhcp "$hardware_port" 2>>"$LOG_FILE"; then
                log_info "✅ [Success] DHCP configuration reapplied successfully"
                sleep 3
                sudo networksetup -detectnewhardware 2>>"$LOG_FILE"
                return 0
            fi
        fi
    fi

    # Method 3: Force hardware redetection
    log_info "🔧 [Method3] Forcing hardware redetection..."
    methods_tried+=("hardware-detect")

    if sudo networksetup -detectnewhardware 2>>"$LOG_FILE"; then
        log_info "✅ [Success] Hardware redetection complete"
        sleep 3
        return 0
    fi

    # All methods failed
    log_error "❌ [Failed] All networksetup methods failed"
    log_info "📋 [Methods tried]: ${methods_tried[*]}"
    log_warn "⚠️  [Note] networksetup method may not support direct MAC address modification in current macOS version"

    return 1
}

# 📊 Enhanced troubleshooting info display
_show_troubleshooting_info() {
    local interface_name="$1"

    echo
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              MAC Address Modification Troubleshooting        ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo

    # 🔍 System info
    echo -e "${BLUE}🔍 System Environment Info:${NC}"
    echo "  📱 macOS Version: $MACOS_VERSION"
    echo "  💻 Hardware Type: $HARDWARE_TYPE"
    echo "  🔒 SIP Status: $SIP_STATUS"
    echo "  🌐 Interface Name: $interface_name"
    echo "  📊 Compatibility Level: ${MAC_COMPATIBILITY_LEVEL:-Unknown}"

    # Display interface detailed info
    local interface_info=$(ifconfig "$interface_name" 2>/dev/null | head -3)
    if [ -n "$interface_info" ]; then
        echo "  📡 Interface Status:"
        echo "$interface_info" | sed 's/^/     /'
    fi
    echo

    # ⚠️ Problem analysis
    echo -e "${BLUE}⚠️  Possible Causes:${NC}"
    local issues_found=false

    if [[ "$HARDWARE_TYPE" == "Apple Silicon" ]] && [[ $MACOS_MAJOR -ge 12 ]]; then
        echo "  ❌ Apple Silicon Mac has hardware-level MAC address modification restrictions in macOS 12+"
        echo "  ❌ Network driver may completely prohibit MAC address modification"
        issues_found=true
    fi

    if [[ $MACOS_MAJOR -ge 14 ]]; then
        echo "  ❌ macOS Sonoma (14+) has strict system-level restrictions on MAC address modification"
        issues_found=true
    elif [[ $MACOS_MAJOR -ge 12 ]]; then
        echo "  ⚠️  macOS Monterey+ has partial restrictions on MAC address modification"
        issues_found=true
    fi

    if [[ "$SIP_STATUS" == "enabled" ]]; then
        echo "  ⚠️  System Integrity Protection (SIP) may block certain MAC address modification methods"
        issues_found=true
    fi

    if ! $issues_found; then
        echo "  ❓ Network interface may not support MAC address modification"
        echo "  ❓ Insufficient permissions or other system security policy restrictions"
    fi
    echo

    # 💡 Solutions
    echo -e "${BLUE}💡 Suggested Solutions:${NC}"
    echo
    echo -e "${GREEN}  🛠️  Solution 1: Install Third-Party Tools${NC}"
    echo "     brew install spoof-mac"
    echo "     brew install macchanger"
    echo "     # These tools may use different underlying methods"
    echo

    if [[ "$HARDWARE_TYPE" == "Apple Silicon" ]] || [[ $MACOS_MAJOR -ge 14 ]]; then
        echo -e "${GREEN}  🔧 Solution 2: Use Cursor JS Kernel Modification (Recommended)${NC}"
        echo "     # This script will automatically attempt the JS kernel modification solution"
        echo "     # Directly modify Cursor kernel files to bypass system MAC detection"
        echo
    fi

    echo -e "${GREEN}  🌐 Solution 3: Network Layer Solutions${NC}"
    echo "     • Use virtual machines to run applications requiring MAC address modification"
    echo "     • Configure router-level MAC address filtering bypass"
    echo "     • Use VPN or proxy services"
    echo

    if [[ "$SIP_STATUS" == "enabled" ]]; then
        echo -e "${YELLOW}  ⚠️  Solution 4: Temporarily Disable SIP (High Risk, Not Recommended)${NC}"
        echo "     1. Restart into Recovery Mode (Command+R)"
        echo "     2. Open Terminal and run: csrutil disable"
        echo "     3. Restart and try to modify MAC address"
        echo "     4. Re-enable when done: csrutil enable"
        echo "     ⚠️  Warning: Disabling SIP reduces system security"
        echo
    fi

    # 🔧 Technical details
    echo -e "${BLUE}🔧 Technical Details and Error Analysis:${NC}"
    echo "  📋 Common Error Messages:"
    echo "     • ifconfig: ioctl (SIOCAIFADDR): Can't assign requested address"
    echo "     • Operation not permitted"
    echo "     • Device or resource busy"
    echo
    echo "  🔍 Error Meanings:"
    echo "     • System kernel rejected MAC address modification request"
    echo "     • Hardware driver does not allow MAC address changes"
    echo "     • Security policy blocked network interface modification"
    echo

    if [[ "$HARDWARE_TYPE" == "Apple Silicon" ]]; then
        echo "  🍎 Apple Silicon Special Notes:"
        echo "     • Hardware-level security restrictions cannot be bypassed by software"
        echo "     • Network chip firmware may have locked the MAC address"
        echo "     • Suggest using application-layer solutions (e.g., JS kernel modification)"
        echo
    fi

    echo -e "${BLUE}📞 Get More Help:${NC}"
    echo "  • View system logs: sudo dmesg | grep -i network"
    echo "  • Check network interfaces: networksetup -listallhardwareports"
    echo "  • Test permissions: sudo ifconfig $interface_name"
    echo
}

# Smart device identification bypass (MAC address modification removed, JS injection only)
run_device_bypass() {
    log_info "🔧 [Device ID] MAC address modification disabled, proceeding directly to JS kernel injection..."

    if modify_cursor_js_files; then
        log_info "✅ [JS] JS kernel injection complete"
        return 0
    fi

    log_error "❌ [JS] JS kernel injection failed"
    return 1
}

# Check permissions
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run this script with sudo"
        echo "Example: sudo $0"
        exit 1
    fi
}

# Check and kill Cursor process (save process info)
check_and_kill_cursor() {
    log_info "🔍 [Check] Checking Cursor process..."

    local attempt=1
    local max_attempts=5

    # 💾 Save Cursor process path
    CURSOR_PROCESS_PATH="/Applications/Cursor.app/Contents/MacOS/Cursor"

    # Function: Get process detailed info
    get_process_details() {
        local process_name="$1"
        log_debug "Getting detailed process info for $process_name:"
        ps aux | grep -i "/Applications/Cursor.app" | grep -v grep
    }

    while [ $attempt -le $max_attempts ]; do
        # Use more precise matching to get Cursor process
        CURSOR_PIDS=$(ps aux | grep -i "/Applications/Cursor.app" | grep -v grep | awk '{print $2}')

        if [ -z "$CURSOR_PIDS" ]; then
            log_info "💡 [Tip] No running Cursor process found"
            # Confirm Cursor app path exists
            if [ -f "$CURSOR_PROCESS_PATH" ]; then
                log_info "💾 [Saved] Cursor path saved: $CURSOR_PROCESS_PATH"
            else
                log_warn "⚠️  [Warning] Cursor app not found, please confirm it is installed"
            fi
            return 0
        fi

        log_warn "⚠️  [Warning] Cursor process is running"
        # 💾 Save process info
        log_info "💾 [Saved] Cursor path saved: $CURSOR_PROCESS_PATH"
        get_process_details "cursor"

        log_warn "🔄 [Action] Attempting to close Cursor process..."

        if [ $attempt -eq $max_attempts ]; then
            log_warn "💥 [Force] Attempting to force terminate process..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi

        sleep 3

        # Also use more precise matching to check if process is still running
        if ! ps aux | grep -i "/Applications/Cursor.app" | grep -v grep > /dev/null; then
            log_info "✅ [Success] Cursor process successfully closed"
            return 0
        fi

        log_warn "⏳ [Wait] Waiting for process to close, attempt $attempt/$max_attempts..."
        ((attempt++))
    done

    log_error "❌ [Error] Unable to close Cursor process after $max_attempts attempts"
    get_process_details "cursor"
    log_error "💥 [Error] Please manually close the process and retry"
    exit 1
}

# Backup config file
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "Config file does not exist, skipping backup"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"

    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        chown "$CURRENT_USER" "$backup_file"
        log_info "Config backed up to: $backup_file"
    else
        log_error "Backup failed"
        exit 1
    fi
}

# Re-set config file to read-only (avoid permission fix override)
protect_storage_file() {
    if [ -f "$STORAGE_FILE" ]; then
        if chmod 444 "$STORAGE_FILE" 2>/dev/null; then
            log_info "🔒 [Protect] Config file re-set to read-only"
        else
            log_warn "⚠️  [Protect] Config file read-only setting failed"
        fi
    fi
}

# 🔧 Modify Cursor kernel JS files to implement device identification bypass (enhanced triple solution)
# Solution A: someValue placeholder replacement - stable anchor, does not depend on obfuscated function names
# Solution B: b6 fixed-point rewrite - machine code source function directly returns fixed value
# Solution C: Loader Stub + External Hook - main/shared processes only load external Hook file
modify_cursor_js_files() {
    log_info "🔧 [Kernel Mod] Starting to modify Cursor kernel JS files to implement device identification bypass..."
    log_info "💡 [Solution] Using enhanced triple solution: placeholder replacement + b6 fixed-point rewrite + Loader Stub + External Hook"
    echo

    # Check if Cursor app exists
    if [ ! -d "$CURSOR_APP_PATH" ]; then
        log_error "❌ [Error] Cursor app not found: $CURSOR_APP_PATH"
        return 1
    fi

    # Generate or reuse device identifiers (prioritize values generated in config)
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
        machine_id=$(generate_hex_bytes 32)
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
        mac_machine_id=$(generate_hex_bytes 32)
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
        log_warn "Some IDs not ready, generated new values for JS injection"
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

    log_info "🔑 [Ready] Device identifiers ready"
    log_info "   machineId: ${machine_id:0:16}..."
    log_info "   machineGuid: ${machine_guid:0:16}..."
    log_info "   deviceId: ${device_id:0:16}..."
    log_info "   macMachineId: ${mac_machine_id:0:16}..."
    log_info "   sqmId: $sqm_id"

    # Save ID config to user directory (for Hook to read)
    # Delete old config and regenerate each execution to ensure new device identifiers are obtained
    local ids_config_path="$TARGET_HOME/.cursor_ids.json"
    if [ -f "$ids_config_path" ]; then
        rm -f "$ids_config_path"
        log_info "🗑️  [Clean] Deleted old ID config file"
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
    log_info "💾 [保存] 新的 ID 配置已保存到: $ids_config_path"

    # 部署外置 Hook 文件（供 Loader Stub 加载，支持多域名备用下载）
    local hook_target_path="$TARGET_HOME/.cursor_hook.js"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local hook_source_path="$script_dir/../hook/cursor_hook.js"
    local hook_download_urls=(
        "https://wget.la/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://down.npee.cn/?https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://xget.xi-xu.me/gh/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh-proxy.com/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
        "https://gh.chjina.com/https://raw.githubusercontent.com/Naster17/go-cursor-help-en/refs/heads/master/scripts/hook/cursor_hook.js"
    )
    # 支持通过环境变量覆盖下载节点（逗号分隔）
    if [ -n "$CURSOR_HOOK_DOWNLOAD_URLS" ]; then
        IFS=',' read -r -a hook_download_urls <<< "$CURSOR_HOOK_DOWNLOAD_URLS"
        log_info "ℹ️  [Hook] 检测到自定义下载节点列表，将优先使用"
    fi

    if [ -f "$hook_source_path" ]; then
        if cp "$hook_source_path" "$hook_target_path"; then
            chown "$TARGET_USER":"$(id -g -n "$TARGET_USER")" "$hook_target_path" 2>/dev/null || true
            log_info "✅ [Hook] 外置 Hook 已部署: $hook_target_path"
        else
            log_warn "⚠️  [Hook] 本地 Hook 复制失败，尝试在线下载..."
        fi
    fi

    if [ ! -f "$hook_target_path" ]; then
        log_info "ℹ️  [Hook] 正在下载外置 Hook，用于设备标识拦截..."
        local hook_downloaded=false
        local total_urls=${#hook_download_urls[@]}
        if [ "$total_urls" -eq 0 ]; then
            log_warn "⚠️  [Hook] 下载节点列表为空，跳过在线下载"
        elif command -v curl >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) 当前下载节点: $url"
                if curl -fL --progress-bar "$url" -o "$hook_target_path"; then
                    chown "$TARGET_USER":"$(id -g -n "$TARGET_USER")" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                else
                    rm -f "$hook_target_path"
                    log_warn "⚠️  [Hook] 外置 Hook 下载失败: $url"
                fi
            done
        elif command -v wget >/dev/null 2>&1; then
            local index=0
            for url in "${hook_download_urls[@]}"; do
                index=$((index + 1))
                log_info "⏳ [Hook] ($index/$total_urls) 当前下载节点: $url"
                if wget --progress=bar:force -O "$hook_target_path" "$url"; then
                    chown "$TARGET_USER":"$(id -g -n "$TARGET_USER")" "$hook_target_path" 2>/dev/null || true
                    log_info "✅ [Hook] 外置 Hook 已在线下载: $hook_target_path"
                    hook_downloaded=true
                    break
                else
                    rm -f "$hook_target_path"
                    log_warn "⚠️  [Hook] 外置 Hook 下载失败: $url"
                fi
            done
        else
            log_warn "⚠️  [Hook] 未检测到 curl/wget，无法在线下载 Hook"
        fi
        if [ "$hook_downloaded" != true ] && [ ! -f "$hook_target_path" ]; then
            log_warn "⚠️  [Hook] 外置 Hook 全部下载失败"
        fi
    fi

    # 目标JS文件列表（main + shared process）
    local js_files=(
        "$CURSOR_APP_PATH/Contents/Resources/app/out/main.js"
        "$CURSOR_APP_PATH/Contents/Resources/app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
    )

    local modified_count=0

    # 关闭Cursor进程
    log_info "🔄 [关闭] 关闭Cursor进程以进行文件修改..."
    check_and_kill_cursor

    # 创建备份目录
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$CURSOR_APP_PATH/Contents/Resources/app/out/backups"

    log_info "💾 [备份] 创建JS文件备份..."
    mkdir -p "$backup_dir"

    # 处理每个文件：创建原始备份或从原始备份恢复
    for file in "${js_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "⚠️  [警告] 文件不存在: ${file/$CURSOR_APP_PATH\//}"
            continue
        fi

        local file_name=$(basename "$file")
        local file_original_backup="$backup_dir/$file_name.original"

        # 如果原始备份不存在，先创建
        if [ ! -f "$file_original_backup" ]; then
            # 检查当前文件是否已被修改过
            if grep -q "__cursor_patched__" "$file" 2>/dev/null; then
                log_warn "⚠️  [警告] 文件已被修改但无原始备份，将使用当前版本作为基础"
            fi
            cp "$file" "$file_original_backup"
            log_info "✅ [备份] 原始备份创建成功: $file_name"
        else
            # 从原始备份恢复，确保每次都是干净的注入
            log_info "🔄 [恢复] 从原始备份恢复: $file_name"
            cp "$file_original_backup" "$file"
        fi
    done

    # 创建时间戳备份（记录每次修改前的状态）
    for file in "${js_files[@]}"; do
        if [ -f "$file" ]; then
            cp "$file" "$backup_dir/$(basename "$file").backup_$timestamp"
        fi
    done
    log_info "✅ [备份] 时间戳备份创建成功: $backup_dir"

    # 修改JS文件（每次都重新注入，因为已从原始备份恢复）
    log_info "🔧 [修改] 开始修改JS文件（使用新的设备标识符）..."

    for file in "${js_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "⚠️  [跳过] 文件不存在: ${file/$CURSOR_APP_PATH\//}"
            continue
        fi

        log_info "📝 [处理] 正在处理: ${file/$CURSOR_APP_PATH\//}"

        # ========== 方法A: someValue占位符替换（稳定锚点） ==========
        # 重要说明：
        # 当前 Cursor 的 main.js 中占位符通常是以字符串字面量形式出现，例如：
        #   this.machineId="someValue.machineId"
        # 如果直接把 someValue.machineId 替换成 "\"<真实值>\""，会形成 ""<真实值>"" 导致 JS 语法错误。
        # 因此这里优先替换完整的字符串字面量（包含外层引号），再兜底替换不带引号的占位符。
        local replaced=false

        if grep -q 'someValue\.machineId' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.machineId\"/\"${machine_id}\"/g" \
                -e "s/'someValue\.machineId'/\"${machine_id}\"/g" \
                -e "s/someValue\.machineId/\"${machine_id}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.machineId"
            replaced=true
        fi

        if grep -q 'someValue\.macMachineId' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.macMachineId\"/\"${mac_machine_id}\"/g" \
                -e "s/'someValue\.macMachineId'/\"${mac_machine_id}\"/g" \
                -e "s/someValue\.macMachineId/\"${mac_machine_id}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.macMachineId"
            replaced=true
        fi

        if grep -q 'someValue\.devDeviceId' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.devDeviceId\"/\"${device_id}\"/g" \
                -e "s/'someValue\.devDeviceId'/\"${device_id}\"/g" \
                -e "s/someValue\.devDeviceId/\"${device_id}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.devDeviceId"
            replaced=true
        fi

        if grep -q 'someValue\.sqmId' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.sqmId\"/\"${sqm_id}\"/g" \
                -e "s/'someValue\.sqmId'/\"${sqm_id}\"/g" \
                -e "s/someValue\.sqmId/\"${sqm_id}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.sqmId"
            replaced=true
        fi

        if grep -q 'someValue\.sessionId' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.sessionId\"/\"${session_id}\"/g" \
                -e "s/'someValue\.sessionId'/\"${session_id}\"/g" \
                -e "s/someValue\.sessionId/\"${session_id}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.sessionId"
            replaced=true
        fi

        if grep -q 'someValue\.firstSessionDate' "$file"; then
            sed -i.tmp \
                -e "s/\"someValue\.firstSessionDate\"/\"${first_session_date}\"/g" \
                -e "s/'someValue\.firstSessionDate'/\"${first_session_date}\"/g" \
                -e "s/someValue\.firstSessionDate/\"${first_session_date}\"/g" \
                "$file"
            log_info "   ✓ [方案A] 替换 someValue.firstSessionDate"
            replaced=true
        fi


        # ========== 方法C: Loader Stub 注入 ==========
        # 注意：使用 CommonJS 语法（require），不使用 ESM 动态 import()
        # 原因：Electron 的 main.js 运行在 CJS 上下文，ESM 动态 import 可能静默失败
        local inject_code='// ========== Cursor Hook Loader 开始 ==========
;(function(){/*__cursor_patched__*/
"use strict";
if(globalThis.__cursor_hook_loaded__)return;
globalThis.__cursor_hook_loaded__=true;

try{
    // 使用 CommonJS require() 语法，确保在 Electron CJS 上下文中正常运行
    var fs=require("fs");
    var path=require("path");
    var os=require("os");

    var hookPath=path.join(os.homedir(), ".cursor_hook.js");
    if(fs.existsSync(hookPath)){
        require(hookPath);
    }
}catch(e){
    // 失败静默，避免影响启动
}
})();
// ========== Cursor Hook Loader 结束 ==========

'

        # 在版权声明后注入代码
        if grep -q '\*/' "$file"; then
            # 使用 awk 在版权声明后注入
            awk -v inject="$inject_code" '
            /\*\// && !injected {
                print
                print ""
                print inject
                injected = 1
                next
            }
            { print }
            ' "$file" > "${file}.new"
            mv "${file}.new" "$file"
            log_info "   ✓ [方案C] Loader Stub 已注入（版权声明后）"
        else
            # 注入到文件开头
            echo "$inject_code" > "${file}.new"
            cat "$file" >> "${file}.new"
            mv "${file}.new" "$file"
            log_info "   ✓ [方案C] Loader Stub 已注入（文件开头）"
        fi

        # 清理临时文件
        rm -f "${file}.tmp"

        local summary="Hook加载器"
        if [ "$replaced" = true ]; then
            summary="someValue替换 + $summary"
        fi
        if [ "$b6_patched" = true ]; then
            summary="b6定点重写 + $summary"
        fi
        log_info "✅ [成功] 增强版方案修改成功（$summary）"
        ((modified_count++))
    done

    if [ $modified_count -gt 0 ]; then
        log_info "🎉 [完成] 成功修改 $modified_count 个JS文件"
        log_info "💾 [备份] 原始文件备份位置: $backup_dir"
        log_info "💡 [说明] 使用增强版三重方案："
        log_info "   • 方案A: someValue占位符替换（稳定锚点，跨版本兼容）"
        log_info "   • 方案B: b6 定点重写（机器码源函数）"
        log_info "   • 方案C: Loader Stub + 外置 Hook（cursor_hook.js）"
        log_info "📁 [配置] ID 配置文件: $ids_config_path"
        return 0
    else
        log_error "❌ [失败] 没有成功修改任何文件"
        return 1
    fi
}




# 修改现有文件
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"

    if [ ! -f "$file" ]; then
        log_error "文件不存在: $file"
        return 1
    fi

    # 确保文件可写
    chmod 644 "$file" || {
        log_error "无法修改文件权限: $file"
        return 1
    }

    # 创建临时文件
    local temp_file=$(mktemp)

    # 检查key是否存在
    if grep -q "\"$key\":" "$file"; then
        # key存在,执行替换
        sed "s/\"$key\":[[:space:]]*\"[^\"]*\"/\"$key\": \"$value\"/" "$file" > "$temp_file" || {
            log_error "修改配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    else
        # key不存在,添加新的key-value对
        sed "s/}$/,\n    \"$key\": \"$value\"\n}/" "$file" > "$temp_file" || {
            log_error "添加配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    fi

    # 检查临时文件是否为空
    if [ ! -s "$temp_file" ]; then
        log_error "生成的临时文件为空"
        rm -f "$temp_file"
        return 1
    fi

    # 使用 cat 替换原文件内容
    cat "$temp_file" > "$file" || {
        log_error "无法写入文件: $file"
        rm -f "$temp_file"
        return 1
    }

    rm -f "$temp_file"

    # 恢复文件权限
    chmod 444 "$file"

    return 0
}

# 清理 Cursor 之前的修改
clean_cursor_app() {
    log_info "尝试清理 Cursor 之前的修改..."

    # 如果存在备份，直接恢复备份
    local latest_backup=""

    # 查找最新的备份
    latest_backup=$(find /tmp -name "Cursor.app.backup_*" -type d -print 2>/dev/null | sort -r | head -1)

    if [ -n "$latest_backup" ] && [ -d "$latest_backup" ]; then
        log_info "找到现有备份: $latest_backup"
        log_info "正在恢复原始版本..."

        # 停止 Cursor 进程
        check_and_kill_cursor

        # 恢复备份
        sudo rm -rf "$CURSOR_APP_PATH"
        sudo cp -R "$latest_backup" "$CURSOR_APP_PATH"
        sudo chown -R "$CURRENT_USER:staff" "$CURSOR_APP_PATH"
        sudo chmod -R 755 "$CURSOR_APP_PATH"

        log_info "已恢复原始版本"
        return 0
    else
        log_warn "未找到现有备份，尝试重新安装 Cursor..."
        echo "您可以从 https://cursor.sh 下载并重新安装 Cursor"
        echo "或者继续执行此脚本，将尝试修复现有安装"

        # 可以在这里添加重新下载和安装的逻辑
        return 1
    fi
}

# 修改 Cursor 主程序文件（安全模式）
modify_cursor_app_files() {
    log_info "正在安全修改 Cursor 主程序文件..."
    log_info "详细日志将记录到: $LOG_FILE"

    # 先清理之前的修改
    clean_cursor_app

    # 验证应用是否存在
    if [ ! -d "$CURSOR_APP_PATH" ]; then
        log_error "未找到 Cursor.app，请确认安装路径: $CURSOR_APP_PATH"
        return 1
    fi

    # 定义目标文件 - 将extensionHostProcess.js放在最前面优先处理
    local target_files=(
        "${CURSOR_APP_PATH}/Contents/Resources/app/out/vs/workbench/api/node/extensionHostProcess.js"
        "${CURSOR_APP_PATH}/Contents/Resources/app/out/main.js"
        "${CURSOR_APP_PATH}/Contents/Resources/app/out/vs/code/node/cliProcessMain.js"
    )

    # 检查文件是否存在并且是否已修改
    local need_modification=false
    local missing_files=false

    log_debug "检查目标文件..."
    for file in "${target_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "文件不存在: ${file/$CURSOR_APP_PATH\//}"
            echo "[FILE_CHECK] 文件不存在: $file" >> "$LOG_FILE"
            missing_files=true
            continue
        fi

        echo "[FILE_CHECK] 文件存在: $file ($(wc -c < "$file") 字节)" >> "$LOG_FILE"

        if ! grep -q "return crypto.randomUUID()" "$file" 2>/dev/null; then
            log_info "文件需要修改: ${file/$CURSOR_APP_PATH\//}"
            grep -n "IOPlatformUUID" "$file" | head -3 >> "$LOG_FILE" || echo "[FILE_CHECK] 未找到 IOPlatformUUID" >> "$LOG_FILE"
            need_modification=true
            break
        else
            log_info "文件已修改: ${file/$CURSOR_APP_PATH\//}"
        fi
    done

    # 如果所有文件都已修改或不存在，则退出
    if [ "$missing_files" = true ]; then
        log_error "部分目标文件不存在，请确认 Cursor 安装是否完整"
        return 1
    fi

    if [ "$need_modification" = false ]; then
        log_info "所有目标文件已经被修改过，无需重复操作"
        return 0
    fi

    # 创建临时工作目录
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local temp_dir="/tmp/cursor_reset_${timestamp}"
    local temp_app="${temp_dir}/Cursor.app"
    local backup_app="/tmp/Cursor.app.backup_${timestamp}"

    log_debug "创建临时目录: $temp_dir"
    echo "[TEMP_DIR] 创建临时目录: $temp_dir" >> "$LOG_FILE"

    # 清理可能存在的旧临时目录
    if [ -d "$temp_dir" ]; then
        log_info "清理已存在的临时目录..."
        rm -rf "$temp_dir"
    fi

    # 创建新的临时目录
    mkdir -p "$temp_dir" || {
        log_error "无法创建临时目录: $temp_dir"
        echo "[ERROR] 无法创建临时目录: $temp_dir" >> "$LOG_FILE"
        return 1
    }

    # 备份原应用
    log_info "备份原应用..."
    echo "[BACKUP] 开始备份: $CURSOR_APP_PATH -> $backup_app" >> "$LOG_FILE"

    cp -R "$CURSOR_APP_PATH" "$backup_app" || {
        log_error "无法创建应用备份"
        echo "[ERROR] 备份失败: $CURSOR_APP_PATH -> $backup_app" >> "$LOG_FILE"
        rm -rf "$temp_dir"
        return 1
    }

    echo "[BACKUP] 备份完成" >> "$LOG_FILE"

    # 复制应用到临时目录
    log_info "创建临时工作副本..."
    echo "[COPY] 开始复制: $CURSOR_APP_PATH -> $temp_dir" >> "$LOG_FILE"

    cp -R "$CURSOR_APP_PATH" "$temp_dir" || {
        log_error "无法复制应用到临时目录"
        echo "[ERROR] 复制失败: $CURSOR_APP_PATH -> $temp_dir" >> "$LOG_FILE"
        rm -rf "$temp_dir" "$backup_app"
        return 1
    }

    echo "[COPY] 复制完成" >> "$LOG_FILE"

    # 确保临时目录的权限正确
    chown -R "$CURRENT_USER:staff" "$temp_dir"
    chmod -R 755 "$temp_dir"

    # 移除签名（增强兼容性）
    log_info "移除应用签名..."
    echo "[CODESIGN] 移除签名: $temp_app" >> "$LOG_FILE"

    codesign --remove-signature "$temp_app" 2>> "$LOG_FILE" || {
        log_warn "移除应用签名失败"
        echo "[WARN] 移除签名失败: $temp_app" >> "$LOG_FILE"
    }

    # 移除所有相关组件的签名
    local components=(
        "$temp_app/Contents/Frameworks/Cursor Helper.app"
        "$temp_app/Contents/Frameworks/Cursor Helper (GPU).app"
        "$temp_app/Contents/Frameworks/Cursor Helper (Plugin).app"
        "$temp_app/Contents/Frameworks/Cursor Helper (Renderer).app"
    )

    for component in "${components[@]}"; do
        if [ -e "$component" ]; then
            log_info "正在移除签名: $component"
            codesign --remove-signature "$component" || {
                log_warn "移除组件签名失败: $component"
            }
        fi
    done

    # 修改目标文件 - 优先处理js文件
    local modified_count=0
    local files=(
        "${temp_app}/Contents/Resources/app/out/vs/workbench/api/node/extensionHostProcess.js"
        "${temp_app}/Contents/Resources/app/out/main.js"
        "${temp_app}/Contents/Resources/app/out/vs/code/node/cliProcessMain.js"
    )

    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "文件不存在: ${file/$temp_dir\//}"
            continue
        fi

        log_debug "处理文件: ${file/$temp_dir\//}"
        echo "[PROCESS] 开始处理文件: $file" >> "$LOG_FILE"
        echo "[PROCESS] 文件大小: $(wc -c < "$file") 字节" >> "$LOG_FILE"

        # 输出文件部分内容到日志
        echo "[FILE_CONTENT] 文件头部 100 行:" >> "$LOG_FILE"
        head -100 "$file" 2>/dev/null | grep -v "^$" | head -50 >> "$LOG_FILE"
        echo "[FILE_CONTENT] ..." >> "$LOG_FILE"

        # 创建文件备份
        cp "$file" "${file}.bak" || {
            log_error "无法创建文件备份: ${file/$temp_dir\//}"
            echo "[ERROR] 无法创建文件备份: $file" >> "$LOG_FILE"
            continue
        }

        # 使用 sed 替换而不是字符串操作
        if [[ "$file" == *"extensionHostProcess.js"* ]]; then
            log_debug "处理 extensionHostProcess.js 文件..."
            echo "[PROCESS_DETAIL] 开始处理 extensionHostProcess.js 文件" >> "$LOG_FILE"

            # 检查是否包含目标代码
            if grep -q 'i.header.set("x-cursor-checksum' "$file"; then
                log_debug "找到 x-cursor-checksum 设置代码"
                echo "[FOUND] 找到 x-cursor-checksum 设置代码" >> "$LOG_FILE"

                # 记录匹配的行到日志
                grep -n 'i.header.set("x-cursor-checksum' "$file" >> "$LOG_FILE"

                # 执行特定的替换
                if sed -i.tmp 's/i\.header\.set("x-cursor-checksum",e===void 0?`${p}${t}`:`${p}${t}\/${e}`)/i.header.set("x-cursor-checksum",e===void 0?`${p}${t}`:`${p}${t}\/${p}`)/' "$file"; then
                    log_info "成功修改 x-cursor-checksum 设置代码"
                    echo "[SUCCESS] 成功完成 x-cursor-checksum 设置代码替换" >> "$LOG_FILE"
                    # 记录修改后的行
                    grep -n 'i.header.set("x-cursor-checksum' "$file" >> "$LOG_FILE"
                    ((modified_count++))
                    log_info "成功修改文件: ${file/$temp_dir\//}"
                else
                    log_error "修改 x-cursor-checksum 设置代码失败"
                    cp "${file}.bak" "$file"
                fi
            else
                log_warn "未找到 x-cursor-checksum 设置代码"
                echo "[FILE_CHECK] 未找到 x-cursor-checksum 设置代码" >> "$LOG_FILE"

                # 记录文件部分内容到日志以便排查
                echo "[FILE_CONTENT] 文件中包含 'header.set' 的行:" >> "$LOG_FILE"
                grep -n "header.set" "$file" | head -20 >> "$LOG_FILE"

                echo "[FILE_CONTENT] 文件中包含 'checksum' 的行:" >> "$LOG_FILE"
                grep -n "checksum" "$file" | head -20 >> "$LOG_FILE"
            fi

            echo "[PROCESS_DETAIL] 完成处理 extensionHostProcess.js 文件" >> "$LOG_FILE"
        elif grep -q "IOPlatformUUID" "$file"; then
            log_debug "找到 IOPlatformUUID 关键字"
            echo "[FOUND] 找到 IOPlatformUUID 关键字" >> "$LOG_FILE"
            grep -n "IOPlatformUUID" "$file" | head -5 >> "$LOG_FILE"

            # 定位 IOPlatformUUID 相关函数
            if grep -q "function a\$" "$file"; then
                # 检查是否已经修改过
                if grep -q "return crypto.randomUUID()" "$file"; then
                    log_info "文件已经包含 randomUUID 调用，跳过修改"
                    ((modified_count++))
                    continue
                fi

                # 针对 main.js 中发现的代码结构进行修改
                if sed -i.tmp 's/function a\$(t){switch/function a\$(t){return crypto.randomUUID(); switch/' "$file"; then
                    log_debug "成功注入 randomUUID 调用到 a\$ 函数"
                    ((modified_count++))
                    log_info "成功修改文件: ${file/$temp_dir\//}"
                else
                    log_error "修改 a\$ 函数失败"
                    cp "${file}.bak" "$file"
                fi
            elif grep -q "async function v5" "$file"; then
                # 检查是否已经修改过
                if grep -q "return crypto.randomUUID()" "$file"; then
                    log_info "文件已经包含 randomUUID 调用，跳过修改"
                    ((modified_count++))
                    continue
                fi

                # 替代方法 - 修改 v5 函数
                if sed -i.tmp 's/async function v5(t){let e=/async function v5(t){return crypto.randomUUID(); let e=/' "$file"; then
                    log_debug "成功注入 randomUUID 调用到 v5 函数"
                    ((modified_count++))
                    log_info "成功修改文件: ${file/$temp_dir\//}"
                else
                    log_error "修改 v5 函数失败"
                    cp "${file}.bak" "$file"
                fi
            else
                # 检查是否已经注入了自定义代码
                if grep -q "// Cursor ID 修改工具注入" "$file"; then
                    log_info "文件已经包含自定义注入代码，跳过修改"
                    ((modified_count++))
                    continue
                fi

                # 新增检查：检查是否已存在 randomDeviceId_ 时间戳模式
                if grep -q "const randomDeviceId_[0-9]\\{10,\\}" "$file"; then
                    log_info "文件已经包含 randomDeviceId_ 模式，跳过通用注入"
                    echo "[FOUND] 文件已包含 randomDeviceId_ 模式，跳过通用注入: $file" >> "$LOG_FILE"
                    ((modified_count++)) # 计为已修改，防止后续尝试其他方法
                    continue
                fi

                # 使用更通用的注入方法
                log_warn "未找到具体函数，尝试使用通用修改方法"
                inject_code="
// Cursor ID 修改工具注入 - $(date +%Y%m%d%H%M%S) - ES模块兼容版本
// 随机设备ID生成器注入 - $(date +%s)
import crypto from 'crypto';

const randomDeviceId_$(date +%s) = () => {
    try {
        return crypto.randomUUID();
    } catch (e) {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
    }
};
"
                # 将代码注入到文件开头
                echo "$inject_code" > "${file}.new"
                cat "$file" >> "${file}.new"
                mv "${file}.new" "$file"

                # 替换调用点
                sed -i.tmp 's/await v5(!1)/randomDeviceId_'"$(date +%s)"'()/g' "$file"
                sed -i.tmp 's/a\$(t)/randomDeviceId_'"$(date +%s)"'()/g' "$file"

                log_debug "完成通用修改"
                ((modified_count++))
                log_info "使用通用方法成功修改文件: ${file/$temp_dir\//}"
            fi
        else
            # 未找到 IOPlatformUUID，可能是文件结构变化
            log_warn "未找到 IOPlatformUUID，尝试替代方法"

            # 检查是否已经注入或修改过
            if grep -q "return crypto.randomUUID()" "$file" || grep -q "// Cursor ID 修改工具注入" "$file"; then
                log_info "文件已经被修改过，跳过修改"
                ((modified_count++))
                continue
            fi

            # 尝试找其他关键函数如 getMachineId 或 getDeviceId
            if grep -q "function t\$()" "$file" || grep -q "async function y5" "$file"; then
                log_debug "找到设备ID相关函数"

                # 修改 MAC 地址获取函数
                if grep -q "function t\$()" "$file"; then
                    sed -i.tmp 's/function t\$(){/function t\$(){return "00:00:00:00:00:00";/' "$file"
                    log_debug "修改 MAC 地址获取函数成功"
                fi

                # 修改设备ID获取函数
                if grep -q "async function y5" "$file"; then
                    sed -i.tmp 's/async function y5(t){/async function y5(t){return crypto.randomUUID();/' "$file"
                    log_debug "修改设备ID获取函数成功"
                fi

                ((modified_count++))
                log_info "使用替代方法成功修改文件: ${file/$temp_dir\//}"
            else
                # 最后尝试的通用方法 - 在文件顶部插入重写函数定义
                log_warn "未找到任何已知函数，使用最通用的方法"

                inject_universal_code="
// Cursor ID 修改工具注入 - $(date +%Y%m%d%H%M%S) - ES模块兼容版本
// 全局拦截设备标识符 - $(date +%s)
import crypto from 'crypto';

// 保存原始函数引用
const originalRandomUUID_$(date +%s) = crypto.randomUUID;

// 重写crypto.randomUUID方法
crypto.randomUUID = function() {
    return '${new_uuid}';
};

// 覆盖所有可能的系统ID获取函数 - 使用globalThis
globalThis.getMachineId = function() { return '${machine_id}'; };
globalThis.getDeviceId = function() { return '${device_id}'; };
globalThis.macMachineId = '${mac_machine_id}';

// 确保在不同环境下都能访问
if (typeof window !== 'undefined') {
    window.getMachineId = globalThis.getMachineId;
    window.getDeviceId = globalThis.getDeviceId;
    window.macMachineId = globalThis.macMachineId;
}

// 确保模块顶层执行
console.log('Cursor全局设备标识符拦截已激活 - ES模块版本');
"
                # 将代码注入到文件开头
                local new_uuid=$(generate_uuid)
                local machine_id="auth0|user_$(generate_hex_bytes 16)"
                local device_id=$(generate_uuid)
                local mac_machine_id=$(generate_hex_bytes 32)

                inject_universal_code=${inject_universal_code//\$\{new_uuid\}/$new_uuid}
                inject_universal_code=${inject_universal_code//\$\{machine_id\}/$machine_id}
                inject_universal_code=${inject_universal_code//\$\{device_id\}/$device_id}
                inject_universal_code=${inject_universal_code//\$\{mac_machine_id\}/$mac_machine_id}

                echo "$inject_universal_code" > "${file}.new"
                cat "$file" >> "${file}.new"
                mv "${file}.new" "$file"

                log_debug "完成通用覆盖"
                ((modified_count++))
                log_info "使用最通用方法成功修改文件: ${file/$temp_dir\//}"
            fi
        fi

        # 添加在关键操作后记录日志
        echo "[MODIFIED] 文件修改后内容:" >> "$LOG_FILE"
        grep -n "return crypto.randomUUID()" "$file" | head -3 >> "$LOG_FILE"

        # 清理临时文件
        rm -f "${file}.tmp" "${file}.bak"
        echo "[PROCESS] 文件处理完成: $file" >> "$LOG_FILE"
    done

    if [ "$modified_count" -eq 0 ]; then
        log_error "未能成功修改任何文件"
        rm -rf "$temp_dir"
        return 1
    fi

    # 重新签名应用（增加重试机制）
    local max_retry=3
    local retry_count=0
    local sign_success=false

    while [ $retry_count -lt $max_retry ]; do
        ((retry_count++))
        log_info "尝试签名 (第 $retry_count 次)..."

        # 使用更详细的签名参数
        if codesign --sign - --force --deep --preserve-metadata=entitlements,identifier,flags "$temp_app" 2>&1 | tee /tmp/codesign.log; then
            # 验证签名
            if codesign --verify -vvvv "$temp_app" 2>/dev/null; then
                sign_success=true
                log_info "应用签名验证通过"
                break
            else
                log_warn "签名验证失败，错误日志："
                cat /tmp/codesign.log
            fi
        else
            log_warn "签名失败，错误日志："
            cat /tmp/codesign.log
        fi
        
        sleep 3
    done

    if ! $sign_success; then
        log_error "经过 $max_retry 次尝试仍无法完成签名"
        log_error "请手动执行以下命令完成签名："
        echo -e "${BLUE}sudo codesign --sign - --force --deep '${temp_app}'${NC}"
        echo -e "${YELLOW}操作完成后，请手动将应用复制到原路径：${NC}"
        echo -e "${BLUE}sudo cp -R '${temp_app}' '/Applications/'${NC}"
        log_info "临时文件保留在：${temp_dir}"
        return 1
    fi

    # 替换原应用
    log_info "安装修改版应用..."
    if ! sudo rm -rf "$CURSOR_APP_PATH" || ! sudo cp -R "$temp_app" "/Applications/"; then
        log_error "应用替换失败，正在恢复..."
        sudo rm -rf "$CURSOR_APP_PATH"
        sudo cp -R "$backup_app" "$CURSOR_APP_PATH"
        rm -rf "$temp_dir" "$backup_app"
        return 1
    fi

    # 清理临时文件
    rm -rf "$temp_dir" "$backup_app"

    # 设置权限
    sudo chown -R "$CURRENT_USER:staff" "$CURSOR_APP_PATH"
    sudo chmod -R 755 "$CURSOR_APP_PATH"

    log_info "Cursor 主程序文件修改完成！原版备份在: $backup_app"
    return 0
}

# 显示文件树结构
show_file_tree() {
    local base_dir=$(dirname "$STORAGE_FILE")
    echo
    log_info "文件结构:"
    echo -e "${BLUE}$base_dir${NC}"
    echo "├── globalStorage"
    echo "│   ├── storage.json (已修改)"
    echo "│   └── backups"

    # 列出备份文件
    if [ -d "$BACKUP_DIR" ]; then
        local backup_files=("$BACKUP_DIR"/*)
        if [ ${#backup_files[@]} -gt 0 ]; then
            for file in "${backup_files[@]}"; do
                if [ -f "$file" ]; then
                    echo "│       └── $(basename "$file")"
                fi
            done
        else
            echo "│       └── (空)"
        fi
    fi
    echo
}

# 显示公众号信息
show_follow_info() {
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${YELLOW}  This tool is free and open source ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo
}

# 禁用自动更新
disable_auto_update() {
    local updater_path="$TARGET_HOME/Library/Application Support/Caches/cursor-updater"
    local app_update_yml="/Applications/Cursor.app/Contents/Resources/app-update.yml"

    echo
    log_info "正在禁用 Cursor 自动更新..."

    # 备份并清空 app-update.yml
    if [ -f "$app_update_yml" ]; then
        log_info "备份并修改 app-update.yml..."
        if ! sudo cp "$app_update_yml" "${app_update_yml}.bak" 2>/dev/null; then
            log_warn "备份 app-update.yml 失败，继续执行..."
        fi

        if sudo bash -c "echo '' > \"$app_update_yml\"" && \
           sudo chmod 444 "$app_update_yml"; then
            log_info "成功禁用 app-update.yml"
        else
            log_error "修改 app-update.yml 失败，请手动执行以下命令："
            echo -e "${BLUE}sudo cp \"$app_update_yml\" \"${app_update_yml}.bak\"${NC}"
            echo -e "${BLUE}sudo bash -c 'echo \"\" > \"$app_update_yml\"'${NC}"
            echo -e "${BLUE}sudo chmod 444 \"$app_update_yml\"${NC}"
        fi
    else
        log_warn "未找到 app-update.yml 文件"
    fi

    # 同时也处理 cursor-updater
    log_info "处理 cursor-updater..."
    if sudo rm -rf "$updater_path" && \
       sudo touch "$updater_path" && \
       sudo chmod 444 "$updater_path"; then
        log_info "成功禁用 cursor-updater"
    else
        log_error "禁用 cursor-updater 失败，请手动执行以下命令："
        echo -e "${BLUE}sudo rm -rf \"$updater_path\" && sudo touch \"$updater_path\" && sudo chmod 444 \"$updater_path\"${NC}"
    fi

    echo
    log_info "验证方法："
    echo "1. 运行命令：ls -l \"$updater_path\""
    echo "   确认文件权限显示为：r--r--r--"
    echo "2. 运行命令：ls -l \"$app_update_yml\""
    echo "   确认文件权限显示为：r--r--r--"
    echo
    log_info "完成后请重启 Cursor"
}

# 新增恢复功能选项
restore_feature() {
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "备份目录不存在"
        return 1
    fi

    # 使用 find 命令获取备份文件列表并存储到数组
    backup_files=()
    while IFS= read -r file; do
        [ -f "$file" ] && backup_files+=("$file")
    done < <(find "$BACKUP_DIR" -name "*.backup_*" -type f 2>/dev/null | sort)

    # 检查是否找到备份文件
    if [ ${#backup_files[@]} -eq 0 ]; then
        log_warn "未找到任何备份文件"
        return 1
    fi

    echo
    log_info "可用的备份文件："

    # 构建菜单选项字符串
    menu_options="退出 - 不恢复任何文件"
    for i in "${!backup_files[@]}"; do
        menu_options="$menu_options|$(basename "${backup_files[$i]}")"
    done

    # 使用菜单选择函数
    select_menu_option "请使用上下箭头选择要恢复的备份文件，按Enter确认:" "$menu_options" 0
    choice=$?

    # 处理用户输入
    if [ "$choice" = "0" ]; then
        log_info "跳过恢复操作"
        return 0
    fi

    # 获取选择的备份文件 (减1是因为第一个选项是"退出")
    local selected_backup="${backup_files[$((choice-1))]}"

    # 验证文件存在性和可读性
    if [ ! -f "$selected_backup" ] || [ ! -r "$selected_backup" ]; then
        log_error "无法访问选择的备份文件"
        return 1
    fi

    # 尝试恢复配置
    if cp "$selected_backup" "$STORAGE_FILE"; then
        chmod 644 "$STORAGE_FILE"
        chown "$CURRENT_USER" "$STORAGE_FILE"
        log_info "已从备份文件恢复配置: $(basename "$selected_backup")"
        return 0
    else
        log_error "恢复配置失败"
        return 1
    fi
}

# 解决"应用已损坏，无法打开"问题
fix_damaged_app() {
    # 🔧 修复：字符串内双引号需转义，避免脚本解析中断
    log_info "正在修复\"应用已损坏\"问题..."

    # 检查Cursor应用是否存在
    if [ ! -d "$CURSOR_APP_PATH" ]; then
        log_error "未找到Cursor应用: $CURSOR_APP_PATH"
        return 1
    fi

    log_info "尝试移除隔离属性..."
    if sudo find "$CURSOR_APP_PATH" -print0 \
         | xargs -0 sudo xattr -d com.apple.quarantine 2>/dev/null
    then
        log_info "成功移除隔离属性"
    else
        log_warn "移除隔离属性失败，尝试其他方法..."
    fi

    log_info "尝试重新签名应用..."
    if sudo codesign --force --deep --sign - "$CURSOR_APP_PATH" 2>/dev/null; then
        log_info "应用重新签名成功"
    else
        log_warn "应用重新签名失败"
    fi

    echo
    log_info "修复完成！请尝试重新打开Cursor应用"
    echo
    echo -e "${YELLOW}如果仍然无法打开，您可以尝试以下方法：${NC}"
    echo "1. 在系统偏好设置->安全性与隐私中，点击\"仍要打开\"按钮"
    echo "2. 暂时关闭Gatekeeper（不建议）: sudo spctl --master-disable"
    echo "3. 重新下载安装Cursor应用"
    echo
    echo -e "${BLUE} 参考链接: https://sysin.org/blog/macos-if-crashes-when-opening/ ${NC}"

    return 0
}

# 新增：通用菜单选择函数
# 参数:
# $1 - 提示信息
# $2 - 选项数组，格式为 "选项1|选项2|选项3"
# $3 - 默认选项索引 (从0开始)
# 返回: 选中的选项索引 (从0开始)
select_menu_option() {
    local prompt="$1"
    IFS='|' read -ra options <<< "$2"
    local default_index=${3:-0}
    local selected_index=$default_index
    local key_input
    local cursor_up='\033[A'
    local cursor_down='\033[B'
    local enter_key=$'\n'

    # 保存光标位置
    tput sc

    # 显示提示信息
    echo -e "$prompt"

    # 第一次显示菜单
    for i in "${!options[@]}"; do
        if [ $i -eq $selected_index ]; then
            echo -e " ${GREEN}►${NC} ${options[$i]}"
        else
            echo -e "   ${options[$i]}"
        fi
    done

    # 循环处理键盘输入
    while true; do
        # 读取单个按键
        read -rsn3 key_input

        # 检测按键
        case "$key_input" in
            # 上箭头键
            $'\033[A')
                if [ $selected_index -gt 0 ]; then
                    ((selected_index--))
                fi
                ;;
            # 下箭头键
            $'\033[B')
                if [ $selected_index -lt $((${#options[@]}-1)) ]; then
                    ((selected_index++))
                fi
                ;;
            # Enter键
            "")
                echo # 换行
                log_info "您选择了: ${options[$selected_index]}"
                return $selected_index
                ;;
        esac

        # 恢复光标位置
        tput rc

        # 重新显示菜单
        for i in "${!options[@]}"; do
            if [ $i -eq $selected_index ]; then
                echo -e " ${GREEN}►${NC} ${options[$i]}"
            else
                echo -e "   ${options[$i]}"
            fi
        done
    done
}

# 主函数
main() {

    # 在显示菜单/流程说明前调整终端窗口大小；不支持则静默忽略
    try_resize_terminal_window

    # 初始化日志文件
    initialize_log
    log_info "脚本启动..."

    # 🚀 启动时权限修复（解决EACCES错误）
    log_info "🚀 [启动时权限] 执行启动时权限修复..."
    ensure_cursor_directory_permissions

    # 记录系统信息
    log_info "系统信息: $(uname -a)"
    log_info "当前用户: $CURRENT_USER"
    log_cmd_output "sw_vers" "macOS 版本信息"
    log_cmd_output "which codesign" "codesign 路径"
    # 修复：统一引号并显式转义，避免引号嵌套导致脚本解析错误
    log_cmd_output "ls -ld \"$CURSOR_APP_PATH\"" "Cursor 应用信息"

    # 新增环境检查
    if [[ $(uname) != "Darwin" ]]; then
        log_error "本脚本仅支持 macOS 系统"
        exit 1
    fi

    clear
    # 显示 Logo
    echo -e "
    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
    "
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}🚀   Cursor Trial Reset Tool          ${NC}"
    echo -e "${YELLOW}💡  This tool is free and open source  ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    echo

    # 🎯 用户选择菜单
    echo
    echo -e "${GREEN}🎯 [选择模式]${NC} 请选择您要执行的操作："
    echo
    echo -e "${BLUE}  1️⃣  仅修改机器码${NC}"
    echo -e "${YELLOW}      • 仅执行机器码修改功能${NC}"
    echo -e "${YELLOW}      • 同步执行 JS 内核注入${NC}"
    echo -e "${YELLOW}      • 跳过文件夹删除/环境重置步骤${NC}"
    echo -e "${YELLOW}      • 保留现有Cursor配置和数据${NC}"
    echo
    echo -e "${BLUE}  2️⃣  重置环境+修改机器码${NC}"
    echo -e "${RED}      • 执行完全环境重置（删除Cursor文件夹）${NC}"
    echo -e "${RED}      • ⚠️  配置将丢失，请注意备份${NC}"
    echo -e "${YELLOW}      • 按照机器代码修改${NC}"
    echo -e "${YELLOW}      • 这相当于当前的完整脚本行为${NC}"
    echo

    # 获取用户选择
    while true; do
        read -p "请输入选择 (1 或 2): " user_choice
        if [ "$user_choice" = "1" ]; then
            echo -e "${GREEN}✅ [选择]${NC} 您选择了：仅修改机器码"
            execute_mode="MODIFY_ONLY"
            break
        elif [ "$user_choice" = "2" ]; then
            echo -e "${GREEN}✅ [选择]${NC} 您选择了：重置环境+修改机器码"
            echo -e "${RED}⚠️  [重要警告]${NC} 此操作将删除所有Cursor配置文件！"
            read -p "确认执行完全重置？(输入 yes 确认，其他任意键取消): " confirm_reset
            if [ "$confirm_reset" = "yes" ]; then
                execute_mode="RESET_AND_MODIFY"
                break
            else
                echo -e "${YELLOW}👋 [取消]${NC} 用户取消重置操作"
                continue
            fi
        else
            echo -e "${RED}❌ [错误]${NC} 无效选择，请输入 1 或 2"
        fi
    done

    echo

    # 📋 根据选择显示执行流程说明
    if [ "$execute_mode" = "MODIFY_ONLY" ]; then
        echo -e "${GREEN}📋 [执行流程]${NC} 仅修改机器码模式将按以下步骤执行："
        echo -e "${BLUE}  1️⃣  检测Cursor配置文件${NC}"
        echo -e "${BLUE}  2️⃣  备份现有配置文件${NC}"
        echo -e "${BLUE}  3️⃣  修改机器码配置${NC}"
        echo -e "${BLUE}  4️⃣  执行 JS 内核注入${NC}"
        echo -e "${BLUE}  5️⃣  显示操作完成信息${NC}"
        echo
        echo -e "${YELLOW}⚠️  [注意事项]${NC}"
        echo -e "${YELLOW}  • 不会删除任何文件夹或重置环境${NC}"
        echo -e "${YELLOW}  • 保留所有现有配置和数据${NC}"
        echo -e "${YELLOW}  • 原配置文件会自动备份${NC}"
        echo -e "${YELLOW}  • 需要Python3环境来处理JSON配置文件${NC}"
    else
        echo -e "${GREEN}📋 [执行流程]${NC} 重置环境+修改机器码模式将按以下步骤执行："
        echo -e "${BLUE}  1️⃣  检测并关闭Cursor进程${NC}"
        echo -e "${BLUE}  2️⃣  保存Cursor程序路径信息${NC}"
        echo -e "${BLUE}  3️⃣  删除指定的Cursor试用相关文件夹${NC}"
        echo -e "${BLUE}      📁 ~/Library/Application Support/Cursor${NC}"
        echo -e "${BLUE}      📁 ~/.cursor${NC}"
        echo -e "${BLUE}  3.5️⃣ 预创建必要目录结构，避免权限问题${NC}"
        echo -e "${BLUE}  4️⃣  重新启动Cursor让其生成新的配置文件${NC}"
        echo -e "${BLUE}  5️⃣  等待配置文件生成完成（最多45秒）${NC}"
        echo -e "${BLUE}  6️⃣  关闭Cursor进程${NC}"
        echo -e "${BLUE}  7️⃣  修改新生成的机器码配置文件${NC}"
        echo -e "${BLUE}  8️⃣  智能设备识别绕过（仅 JS 内核注入）${NC}"
        echo -e "${BLUE}  9️⃣  禁用自动更新${NC}"
        echo -e "${BLUE}  🔟  显示操作完成统计信息${NC}"
        echo
        echo -e "${YELLOW}⚠️  [注意事项]${NC}"
        echo -e "${YELLOW}  • 脚本执行过程中请勿手动操作Cursor${NC}"
        echo -e "${YELLOW}  • 建议在执行前关闭所有Cursor窗口${NC}"
        echo -e "${YELLOW}  • 执行完成后需要重新启动Cursor${NC}"
        echo -e "${YELLOW}  • 原配置文件会自动备份到backups文件夹${NC}"
        echo -e "${YELLOW}  • 需要Python3环境来处理JSON配置文件${NC}"
        echo -e "${YELLOW}  • 已移除 MAC 地址修改，仅保留 JS 注入方案${NC}"
    fi
    echo

    # 🤔 用户确认
    echo -e "${GREEN}🤔 [确认]${NC} 请确认您已了解上述执行流程"
    read -p "是否继续执行？(输入 y 或 yes 继续，其他任意键退出): " confirmation
    if [[ ! "$confirmation" =~ ^(y|yes)$ ]]; then
        echo -e "${YELLOW}👋 [退出]${NC} 用户取消执行，脚本退出"
        exit 0
    fi
    echo -e "${GREEN}✅ [确认]${NC} 用户确认继续执行"
    echo

    # 🚀 根据用户选择执行相应功能
    if [ "$execute_mode" = "MODIFY_ONLY" ]; then
        log_info "🚀 [开始] 开始执行仅修改机器码功能..."

        # 先进行环境检查
        if ! test_cursor_environment "MODIFY_ONLY"; then
            echo
            log_error "❌ [环境检查失败] 无法继续执行"
            echo
            log_info "💡 [建议] 请选择以下操作："
            echo -e "${BLUE}  1️⃣  选择'重置环境+修改机器码'选项（推荐）${NC}"
            echo -e "${BLUE}  2️⃣  手动启动Cursor一次，然后重新运行脚本${NC}"
            echo -e "${BLUE}  3️⃣  检查Cursor是否正确安装${NC}"
            echo -e "${BLUE}  4️⃣  安装Python3: brew install python3${NC}"
            echo
            read -p "按回车键退出..."
            exit 1
        fi

        # 执行机器码修改
        if modify_machine_code_config "MODIFY_ONLY"; then
            echo
            log_info "🎉 [完成] 机器码修改完成！"
            log_info "💡 [提示] 现在可以启动Cursor使用新的机器码配置"
            echo
            log_info "🔧 [设备识别] 正在执行 JS 内核注入..."
            if modify_cursor_js_files; then
                log_info "✅ [设备识别] JS 内核注入完成"
            else
                log_warn "⚠️  [设备识别] JS 内核注入失败，请检查日志"
            fi
        else
            echo
            log_error "❌ [失败] 机器码修改失败！"
            log_info "💡 [建议] 请尝试'重置环境+修改机器码'选项"
        fi
        # 🚫 禁用自动更新（仅修改模式也需要）
        echo
        log_info "🚫 [禁用更新] 正在禁用Cursor自动更新..."
        disable_auto_update

        # 🛡️ 关键修复：仅修改模式的权限修复
        echo
        log_info "🛡️ [权限修复] 执行仅修改模式的权限修复..."
        log_info "💡 [说明] 确保Cursor应用能够正常启动，无权限错误"
        ensure_cursor_directory_permissions

        # 🔧 关键修复：修复应用签名问题（防止"应用已损坏"错误）
        echo
        log_info "🔧 [应用修复] 正在修复Cursor应用签名问题..."
        log_info "💡 [说明] 防止出现'应用已损坏，无法打开'的错误"

        if fix_damaged_app; then
            log_info "✅ [应用修复] Cursor应用签名修复成功"
        else
            log_warn "⚠️  [应用修复] 应用签名修复失败，可能需要手动处理"
            log_info "💡 [建议] 如果Cursor无法启动，请在系统偏好设置中允许打开"
        fi
    else
        # 完整的重置环境+修改机器码流程
        log_info "🚀 [开始] 开始执行重置环境+修改机器码功能..."

        # 🚀 执行主要功能
        check_permissions
        check_and_kill_cursor

        # 🚨 重要警告提示
        echo
        echo -e "${RED}🚨 [重要警告]${NC} ============================================"
        log_warn "⚠️  [风控提醒] Cursor 风控机制非常严格！"
        log_warn "⚠️  [必须删除] 必须完全删除指定文件夹，不能有任何残留设置"
        log_warn "⚠️  [防掉试用] 只有彻底清理才能有效防止掉试用Pro状态"
        echo -e "${RED}🚨 [重要警告]${NC} ============================================"
        echo

        # 🎯 执行 Cursor 防掉试用Pro删除文件夹功能
        log_info "🚀 [开始] 开始执行核心功能..."
        remove_cursor_trial_folders

        # 🔄 重启Cursor让其重新生成配置文件
        restart_cursor_and_wait

        # 🛠️ 修改机器码配置
        modify_machine_code_config

        # 🔧 智能设备识别绕过（仅 JS 内核注入）
        echo
        log_info "🔧 [设备识别] 开始智能设备识别绕过..."
        log_info "💡 [说明] 已移除 MAC 地址修改，直接使用 JS 内核注入"
        if ! run_device_bypass; then
            log_warn "⚠️  [设备识别] 智能设备识别绕过未完全成功，请查看日志"
        fi


        # 🔧 关键修复：修复应用签名问题（防止"应用已损坏"错误）
        echo
        log_info "🔧 [应用修复] 正在修复Cursor应用签名问题..."
        log_info "💡 [说明] 防止出现'应用已损坏，无法打开'的错误"

        if fix_damaged_app; then
            log_info "✅ [应用修复] Cursor应用签名修复成功"
        else
            log_warn "⚠️  [应用修复] 应用签名修复失败，可能需要手动处理"
            log_info "💡 [建议] 如果Cursor无法启动，请在系统偏好设置中允许打开"
        fi
    fi

    # 🚫 禁用自动更新
    echo
    log_info "🚫 [禁用更新] 正在禁用Cursor自动更新..."
    disable_auto_update

    # 🎉 显示操作完成信息
    echo
    log_info "🎉 [完成] Cursor 防掉试用Pro删除操作已完成！"
    echo

    echo
    log_info "🚀 [提示] 现在可以重新启动 Cursor 尝试使用了！"
    echo

    # 🎉 显示修改结果总结
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${BLUE}   🎯 修改结果总结     ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}✅ JSON配置文件修改: 完成${NC}"
    echo -e "${GREEN}✅ 自动更新禁用: 完成${NC}"
    echo -e "${GREEN}================================${NC}"
    echo

    # 🛡️ 脚本完成前最终权限修复
    echo
    log_info "🛡️ [最终权限修复] 执行脚本完成前的最终权限修复..."
    ensure_cursor_directory_permissions
    protect_storage_file

    # 🎉 脚本执行完成
    log_info "🎉 [完成] 所有操作已完成！"
    echo
    log_info "💡 [重要提示] 完整的Cursor破解流程已执行："
    echo -e "${BLUE}  ✅ 机器码配置文件修改${NC}"
    echo -e "${BLUE}  ✅ 自动更新功能禁用${NC}"
    echo -e "${BLUE}  ✅ 权限修复和验证${NC}"
    echo
    log_warn "⚠️  [注意] 重启 Cursor 后生效"
    echo
    log_info "🚀 [下一步] 现在可以启动 Cursor 尝试使用了！"
    echo

    # 记录脚本完成信息
    log_info "📝 [日志] 脚本执行完成"
    echo "========== Cursor 防掉试用Pro删除工具日志结束 $(date) ==========" >> "$LOG_FILE"

    # 显示日志文件位置
    echo
    log_info "📄 [日志] 详细日志已保存到: $LOG_FILE"
    echo "如遇问题请将此日志文件提供给开发者以协助排查"
    echo
}

# 执行主函数
main

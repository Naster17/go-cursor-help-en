#!/bin/bash

# Trae ID Modifier for Linux
# Resets telemetry and hardware identifiers for Trae editor.

set -e

# Path definitions
TRAE_CONFIG_DIR="$HOME/.config/Trae"
STORAGE_FILE="$TRAE_CONFIG_DIR/User/globalStorage/storage.json"
MACHINE_ID_FILE="$TRAE_CONFIG_DIR/machineid"
BACKUP_DIR="$TRAE_CONFIG_DIR/User/globalStorage/backups"

echo "=== Trae ID Modifier Tool ==="

# 1. Kill Trae processes
echo "[1/5] Closing Trae processes..."
pkill -ix trae || true
sleep 1

# 2. Backup existing configuration
if [ -f "$STORAGE_FILE" ]; then
    echo "[2/5] Backing up storage.json..."
    mkdir -p "$BACKUP_DIR"
    cp "$STORAGE_FILE" "$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
else
    echo "Error: Trae configuration not found at $STORAGE_FILE"
    exit 1
fi

# 3. Generate new random IDs
echo "[3/5] Generating new identifiers..."
NEW_MACHINE_ID=$(openssl rand -hex 32)
NEW_MAC_MACHINE_ID=$(openssl rand -hex 32)
NEW_DEV_DEVICE_ID=$(cat /proc/sys/kernel/random/uuid)
NEW_SQM_ID="{$(cat /proc/sys/kernel/random/uuid | tr '[:lower:]' '[:upper:]')}"
NEW_SERVICE_MACHINE_ID=$(cat /proc/sys/kernel/random/uuid)

# 4. Update storage.json
echo "[4/5] Updating storage.json..."

TEMP_STORAGE=$(mktemp)
cp "$STORAGE_FILE" "$TEMP_STORAGE"

update_key() {
    local key=$1
    local value=$2
    sed -i "s/\"$key\": \".*\"/\"$key\": \"$value\"/" "$TEMP_STORAGE"
}

update_key "telemetry.machineId" "$NEW_MACHINE_ID"
update_key "machineId" "$NEW_MACHINE_ID"
update_key "telemetry.macMachineId" "$NEW_MAC_MACHINE_ID"
update_key "telemetry.devDeviceId" "$NEW_DEV_DEVICE_ID"
update_key "deviceId" "$NEW_DEV_DEVICE_ID"
update_key "telemetry.sqmId" "$NEW_SQM_ID"
update_key "storage.serviceMachineId" "$NEW_SERVICE_MACHINE_ID"

mv "$TEMP_STORAGE" "$STORAGE_FILE"

# 5. Update machineid file and set read-only
echo "[5/5] Updating machineid file..."
chmod +w "$MACHINE_ID_FILE" 2>/dev/null || true
echo -n "$NEW_SERVICE_MACHINE_ID" > "$MACHINE_ID_FILE"
chmod 444 "$MACHINE_ID_FILE"

echo "=============================="
echo "Successfully reset Trae IDs!"
echo "New Machine ID: ${NEW_MACHINE_ID:0:12}..."
echo "New Device ID:  $NEW_DEV_DEVICE_ID"
echo "=============================="

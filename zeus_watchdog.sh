#!/system/bin/sh
# =========================================================
# ZEUS: Watchdog — Daemon Recovery Service
# =========================================================
# Purpose: Monitors and restarts failed background daemons.
# Execution: Run via crontab or a continuous loop.
# =========================================================

# Path configuration for PID files
BATTERY_PID="/data/local/tmp/zeus_battery.pid"
COOLER_PID="/data/local/tmp/zeus_cooler.pid"

# Function to check if a process is still running
# Returns 0 if active, 1 if dead/missing
is_alive() {
    # Extract PID from the file
    PID=$(cat "$1" 2>/dev/null)
    # Check if PID exists and process responds to signal 0
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}

# Check and recover Battery Daemon
if ! is_alive "$BATTERY_PID"; then
    echo "[WATCHDOG] Battery daemon not found. Restarting..."
    sh /data/local/tmp/zeus_battery.sh &
    sleep 1
fi

# Check and recover Cooler Daemon
if ! is_alive "$COOLER_PID"; then
    echo "[WATCHDOG] Cooler daemon not found. Restarting..."
    sh /data/local/tmp/zeus_cooler.sh &
    sleep 1
fi

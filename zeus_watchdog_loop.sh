#!/system/bin/sh
# =========================================================
# ZEUS: Watchdog Loop — Continuous Monitoring
# =========================================================
# Purpose: Executes the watchdog script every 15 seconds
# to ensure system daemons are always running.
#
# Execution: nohup sh /data/local/tmp/zeus_watchdog_loop.sh &
# =========================================================

# Path to store the loop's own Process ID
PID_FILE="/data/local/tmp/zeus_watchdog.pid"
echo $$ > "$PID_FILE"

# --- Main Monitoring Loop ---
while true; do
    # Execute the primary watchdog check
    sh /data/local/tmp/zeus_watchdog.sh
    
    # Wait for the next check interval
    sleep 15
done

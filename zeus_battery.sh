#!/system/bin/sh
# =========================================================
# ZEUS: Battery Daemon
# =========================================================
# Logic:
# <= 80% → Charging ON (input_suspend = 0)
# > 80%  → Charging OFF (input_suspend = 1)
# <= 40% → EMERGENCY: Charging ON + Telegram Alert
#
# Usage: sh /data/local/tmp/zeus_battery.sh &
# =========================================================

# --- Configuration ---
HIGH_THRESHOLD=80
LOW_THRESHOLD=40
CHECK_INTERVAL=15
PID_FILE="/data/local/tmp/zeus_battery.pid"

# --- Hardware Paths ---
# Note: These paths are specific to certain Qualcomm devices
INPUT_SUSPEND="/sys/class/qcom-battery/input_suspend"
CAPACITY="/sys/class/power_supply/battery/capacity"

# --- Telegram Notifications ---
TG_TOKEN="BOT:TOKEN"
TG_CHAT="YOUR-TELEGRAM-ID"

# Save Process ID
echo $$ > "$PID_FILE"

# Function to send Telegram alerts
send_notification() {
    local message="$1"
    # Using fixed IP for api.telegram.org to bypass potential DNS issues on mobile
    curl -s --connect-timeout 5 --max-time 10 \
        --resolve "api.telegram.org:443:149.154.167.220" \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" -d "text=${message}" -d "parse_mode=HTML" >/dev/null 2>&1
}

EMERGENCY_SENT=0

# --- Main Loop ---
while true; do
    # Read State of Charge (SOC) and current Suspend status
    SOC=$(cat "$CAPACITY" 2>/dev/null || echo 50)
    SUSPEND_STATUS=$(cat "$INPUT_SUSPEND" 2>/dev/null || echo 0)

    # CASE 1: Emergency Low Battery
    if [ "$SOC" -le "$LOW_THRESHOLD" ] && [ "$SUSPEND_STATUS" = "1" ]; then
        echo 0 > "$INPUT_SUSPEND"
        echo "[ZEUS] EMERGENCY: ${SOC}% <= ${LOW_THRESHOLD}% -> Charging ENABLED"
        
        if [ "$EMERGENCY_SENT" = "0" ]; then
            send_notification "⚠️ <b>ZEUS: Battery ${SOC}%</b> — Emergency charging enabled."
            EMERGENCY_SENT=1
        fi

    # CASE 2: High Battery Threshold Reached
    elif [ "$SOC" -gt "$HIGH_THRESHOLD" ] && [ "$SUSPEND_STATUS" = "0" ]; then
        echo 1 > "$INPUT_SUSPEND"
        EMERGENCY_SENT=0 # Reset emergency notification flag
        echo "[ZEUS] Level: ${SOC}% > ${HIGH_THRESHOLD}% -> Running on BATTERY"

    # CASE 3: Normal Recharge (Falling below High Threshold)
    elif [ "$SOC" -le "$HIGH_THRESHOLD" ] && [ "$SUSPEND_STATUS" = "1" ]; then
        # Ensure we don't flip back to charging immediately unless under threshold
        # This acts as a simple hysteresis 
        echo 0 > "$INPUT_SUSPEND"
        echo "[ZEUS] Level: ${SOC}% <= ${HIGH_THRESHOLD}% -> Running on AC POWER"
    fi

    sleep "$CHECK_INTERVAL"
done

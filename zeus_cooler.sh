#!/system/bin/sh
# =========================================================
# ZEUS: Cooler Daemon & System Protection
# Reads config from /data/local/tmp/zeus_cooler.conf
# =========================================================
# Start: sh /data/local/tmp/zeus_cooler.sh &
# Stop:  kill $(cat /data/local/tmp/zeus_cooler.pid)
# =========================================================

CONF="/data/local/tmp/zeus_cooler.conf"
PID_FILE="/data/local/tmp/zeus_cooler.pid"
SONOFF="/data/local/tmp/sonoff_ctl"
TEMP_FILE="/sys/class/thermal/thermal_zone0/temp"

# Function to extract values from the config file
cfg() { grep "^$1=" "$CONF" | cut -d= -f2; }

# Load Configuration
TEMP_LIMIT=$(cfg TEMP_LIMIT)
TEMP_HYST=$(cfg TEMP_HYST)
CHECK_INTERVAL=$(cfg CHECK_INTERVAL)
TEMP_CRITICAL_HIGH=$(cfg TEMP_CRITICAL_HIGH)
TEMP_CRITICAL_LOW=$(cfg TEMP_CRITICAL_LOW)
TG_BOT_TOKEN=$(cfg TG_BOT_TOKEN)
TG_CHAT_ID=$(cfg TG_CHAT_ID)

# Set Default Values if config is missing entries
TEMP_LIMIT=${TEMP_LIMIT:-45}
TEMP_HYST=${TEMP_HYST:-42}
CHECK_INTERVAL=${CHECK_INTERVAL:-2}
TEMP_CRITICAL_HIGH=${TEMP_CRITICAL_HIGH:-55}
TEMP_CRITICAL_LOW=${TEMP_CRITICAL_LOW:-0}

# Save Process ID
echo $$ > "$PID_FILE"
FAN_STATE="unknown"

# Telegram notification function
tg_send() {
    # Using --resolve because DNS may fail if certain services are stopped
    curl -s --connect-timeout 5 --max-time 10 \
        --resolve "api.telegram.org:443:149.154.167.220" \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=$1" \
        -d "parse_mode=HTML" >/dev/null 2>&1
}

# Critical thermal management function
emergency_stop() {
    REASON="$1"
    echo "[CRITICAL] $REASON"

    # Turn cooler ON immediately for maximum cooling
    $SONOFF on >/dev/null 2>&1

    # Kill user-heavy AI processes (ollama, llama, etc.)
    killall ollama 2>/dev/null
    killall llamafile 2>/dev/null
    killall llama-server 2>/dev/null

    # Kill general high-load stress test processes
    for PID in $(ps -eo PID,ARGS | grep -E "dd |stress|bench" | grep -v grep | awk '{print $1}'); do
        kill -9 $PID 2>/dev/null
    done

    # Gather thermal data for the report
    BAT_TEMP=$(($(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0) / 10))
    CPU_TEMP=$(($(cat $TEMP_FILE 2>/dev/null || echo 0) / 1000))
    BAT_SOC=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "?")

    MSG="🚨 <b>ZEUS: EMERGENCY STOP</b>

⚠️ ${REASON}

🔥 CPU: ${CPU_TEMP}°C
🔋 Battery: ${BAT_TEMP}°C / ${BAT_SOC}%
💨 Cooler: ON

All heavy processes have been terminated."

    tg_send "$MSG"
    echo "[CRITICAL] Telegram alert sent. Waiting for cooldown..."

    # Monitor cooldown period
    while true; do
        sleep 10
        CT=$(($(cat $TEMP_FILE 2>/dev/null || echo 0) / 1000))
        # Wait until temperature is safe and above freezing
        if [ "$CT" -le "$TEMP_HYST" ] && [ "$CT" -ge 5 ]; then
            echo "[CRITICAL] Temperature normalized: ${CT}C"
            tg_send "✅ ZEUS: Temperature normalized (${CT}°C). Cooler active. Processes were NOT restarted — manual start required."
            break
        fi
    done
}

echo "[cooler] PID $$, limit=${TEMP_LIMIT}C, hyst=${TEMP_HYST}C, critical=${TEMP_CRITICAL_HIGH}C/${TEMP_CRITICAL_LOW}C"

# Initialize: Ensure cooler is OFF at startup
$SONOFF off >/dev/null 2>&1
FAN_STATE="off"

# --- Main Thermal Loop ---
while true; do
    RAW=$(cat $TEMP_FILE 2>/dev/null || echo 0)
    CPU_TEMP=$((RAW / 1000))

    # Check for Critical High Temperature
    if [ "$CPU_TEMP" -ge "$TEMP_CRITICAL_HIGH" ]; then
        emergency_stop "CPU OVERHEAT: ${CPU_TEMP}°C >= ${TEMP_CRITICAL_HIGH}°C"
        FAN_STATE="on"
    
    # Check for Critical Low Temperature (sensor error or extreme cold)
    elif [ "$CPU_TEMP" -le "$TEMP_CRITICAL_LOW" ] && [ "$RAW" -gt 0 ]; then
        emergency_stop "CPU UNDERCOOLING: ${CPU_TEMP}°C <= ${TEMP_CRITICAL_LOW}°C"
        FAN_STATE="on"
    
    # Standard Thermostat Logic: Trigger ON
    elif [ "$CPU_TEMP" -ge "$TEMP_LIMIT" ] && [ "$FAN_STATE" != "on" ]; then
        $SONOFF on >/dev/null 2>&1 && FAN_STATE="on"
        echo "[cooler] ${CPU_TEMP}C >= ${TEMP_LIMIT}C -> fan ON"
    
    # Standard Thermostat Logic: Trigger OFF (Hysteresis)
    elif [ "$CPU_TEMP" -le "$TEMP_HYST" ] && [ "$FAN_STATE" != "off" ]; then
        $SONOFF off >/dev/null 2>&1 && FAN_STATE="off"
        echo "[cooler] ${CPU_TEMP}C <= ${TEMP_HYST}C -> fan OFF"
    fi

    sleep $CHECK_INTERVAL
done

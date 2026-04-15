#!/system/bin/sh
# adb shell "su -c 'sh /data/local/tmp/zeus_status.sh'"

CPU_RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
CPU_T=$((CPU_RAW / 1000))

BAT_RAW=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)
BAT_T=$((BAT_RAW / 10))

SOC=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 0)
BAT_ST=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo ?)

BAT_CUR=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
BAT_CUR_MA=$((BAT_CUR / 1000))

BAT_VOLT=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)
BAT_VOLT_MV=$((BAT_VOLT / 1000))

USB_CUR=$(cat /sys/class/power_supply/usb/current_now 2>/dev/null || echo 0)
USB_CUR_MA=$((USB_CUR / 1000))

USB_VOLT=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null || echo 0)
USB_VOLT_MV=$((USB_VOLT / 1000))

USB_POWER_MW=$((USB_CUR_MA * USB_VOLT_MV / 1000))

INPUT_SUSP=$(cat /sys/class/qcom-battery/input_suspend 2>/dev/null || echo ?)

FREE_RAM=$(free -m 2>/dev/null | grep "^Mem:" | awk '{print $4}')
TOTAL_RAM=$(free -m 2>/dev/null | grep "^Mem:" | awk '{print $2}')

if [ "$SOC" -ge 80 ]; then BAT_ICON="🔋"; elif [ "$SOC" -ge 40 ]; then BAT_ICON="🔋"; else BAT_ICON="🪫"; fi
if [ "$CPU_T" -ge 50 ]; then TEMP_ICON="🔴"; elif [ "$CPU_T" -ge 45 ]; then TEMP_ICON="🟠"; elif [ "$CPU_T" -ge 35 ]; then TEMP_ICON="🟡"; else TEMP_ICON="🟢"; fi

if [ "$INPUT_SUSP" = "1" ]; then
    PWR_SRC="🔋 Battery"
    BAT_DIR="discharging"
else
    PWR_SRC="🔌 Charger"
    if [ "$BAT_CUR_MA" -lt 0 ]; then BAT_DIR="charging"; else BAT_DIR="discharging (charger insufficient)"; fi
fi

COOLER_PID=$(cat /data/local/tmp/zeus_cooler.pid 2>/dev/null)
if [ -n "$COOLER_PID" ] && kill -0 "$COOLER_PID" 2>/dev/null; then
    if [ "$CPU_T" -ge "$(($(grep '^TEMP_LIMIT=' /data/local/tmp/zeus_cooler.conf 2>/dev/null | cut -d= -f2 || echo 45)))" ]; then
        COOLER="🌀 ON (daemon ✅)"
    else
        COOLER="💤 OFF (daemon ✅)"
    fi
else
    COOLER="❌ daemon not running"
fi

BAT_PID=$(cat /data/local/tmp/zeus_battery.pid 2>/dev/null)
if [ -n "$BAT_PID" ] && kill -0 "$BAT_PID" 2>/dev/null; then
    BAT_DAEMON="✅ running"
else
    BAT_DAEMON="❌ not running"
fi

echo ""
echo "═══════════════════════════════════"
echo "         ⚡ ZEUS — STATUS ⚡"
echo "═══════════════════════════════════"
echo ""
echo "  ${TEMP_ICON} CPU:        ${CPU_T}°C"
echo "  🌡  Battery:   ${BAT_T}°C"
echo ""
echo "  ${BAT_ICON} Charge:     ${SOC}% (${BAT_ST})"
echo "  ⚡ Source:     ${PWR_SRC}"
echo "  📊 Battery:    ${BAT_DIR} (${BAT_CUR_MA} mA)"
echo ""
echo "  🔌 USB in:     ${USB_CUR_MA} mA × ${USB_VOLT_MV} mV = ${USB_POWER_MW} mW"
echo "  🔋 Bat current: ${BAT_CUR_MA} mA × ${BAT_VOLT_MV} mV"
echo ""
echo "  💾 RAM:        ${FREE_RAM} / ${TOTAL_RAM} MB free"
echo ""
echo "  💨 Cooler:     ${COOLER}"
echo "  🔋 Bat daemon: ${BAT_DAEMON}"
echo "═══════════════════════════════════"
echo ""

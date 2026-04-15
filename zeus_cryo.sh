#!/system/bin/sh
# ==============================================
# ZEUS: Cryo-Sleep + Wi-Fi
# Xiaomi 12 Pro (zeus), LineageOS
# ==============================================
# Run:     adb shell "su -c 'sh /data/local/tmp/zeus_cryo.sh'"
# Restore: reboot

# Termux / Ollama environment
export PATH=/data/data/com.termux/files/usr/bin:$PATH
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib/ollama:$LD_LIBRARY_PATH
export OLLAMA_MODELS="/data/data/com.termux/files/home/.ollama/models"

SSID="YOUR-WIFI-SSID"
PSK="YOUR-WIFI-PASSWORD"
STATIC_IP="192.168.1.45" 
GATEWAY="192.168.1.1"
DNS1="192.168.1.1"
DNS2="8.8.8.8"
IFACE="wlan0"

WPA_SUP="/data/local/tmp/wpa_supplicant_static"
WPA_CLI="/data/local/tmp/wpa_cli_static"
WPA_CONF="/data/local/tmp/wpa_supplicant.conf"
WPA_CTRL="/data/local/tmp/wpa_sockets"
WPA_PID_FILE="/data/local/tmp/wpa_sup.pid"

echo "⚡ [1/5] Stopping Android framework..."
stop
stop logd
stop statsd
stop perfetto
logcat -c 2>/dev/null
sleep 3

echo "📡 [2/5] Starting Wi-Fi..."
killall wpa_supplicant 2>/dev/null
sleep 1

mkdir -p "$WPA_CTRL"
cat > "$WPA_CONF" <<EOF
ctrl_interface=$WPA_CTRL
update_config=1
ap_scan=1
network={
    ssid="$SSID"
    psk="$PSK"
    key_mgmt=WPA-PSK
    proto=RSN WPA
    pairwise=CCMP TKIP
    group=CCMP TKIP
}
EOF

ip link set $IFACE up
sleep 1
$WPA_SUP -Dnl80211 -i$IFACE -c$WPA_CONF -P$WPA_PID_FILE -B
sleep 2

PID=$(cat $WPA_PID_FILE 2>/dev/null)
if [ -z "$PID" ]; then
    echo "   [FAIL] wpa_supplicant failed to start!"
    exit 1
fi

CONNECTED=0
for i in $(seq 1 20); do
    STATUS=$($WPA_CLI -p$WPA_CTRL -i$IFACE status 2>/dev/null | grep "wpa_state=COMPLETED")
    if [ -n "$STATUS" ]; then
        CONNECTED=1
        echo "   [+] Wi-Fi connected in ${i}s"
        break
    fi
    sleep 1
done
if [ "$CONNECTED" -eq 0 ]; then
    $WPA_CLI -p$WPA_CTRL -i$IFACE scan 2>/dev/null
    sleep 3
    $WPA_CLI -p$WPA_CTRL -i$IFACE reassociate 2>/dev/null
    sleep 5
    STATUS=$($WPA_CLI -p$WPA_CTRL -i$IFACE status 2>/dev/null | grep "wpa_state=COMPLETED")
    if [ -z "$STATUS" ]; then
        echo "   [FAIL] Wi-Fi connection failed"
        exit 1
    fi
fi

ip addr flush dev $IFACE
ip addr add ${STATIC_IP}/24 dev $IFACE
ip rule del prio 31000 2>/dev/null
ip route flush table $IFACE 2>/dev/null
ip route flush table main 2>/dev/null
ip rule add from all lookup $IFACE prio 31000
ip route add 192.168.1.0/24 dev $IFACE table $IFACE
ip route add default via $GATEWAY dev $IFACE table $IFACE
setprop net.dns1 $DNS1 2>/dev/null
setprop net.dns2 $DNS2 2>/dev/null

echo "🧊 [3/5] Freezing unused subsystems..."
pkill -STOP -f surfaceflinger
pkill -STOP -f bootanimation
pkill -STOP -f "display.composer"
pkill -STOP -f "display.allocator"
pkill -STOP -f gpuservice
pkill -STOP -f "camera.provider"
pkill -STOP -f cameraserver
pkill -STOP -f audioserver
pkill -STOP -f "audio.service"
pkill -STOP -f "audio.qc.codec"
pkill -STOP -f "media.swcodec"
pkill -STOP -f "media.hwcodec"
pkill -STOP -f "media.extractor"
pkill -STOP -f mediaserver
pkill -STOP -f "media.metrics"
pkill -STOP -f qcrilNrd
pkill -STOP -f rild
pkill -STOP -f imsdaemon
pkill -STOP -f ims_rtp_daemon
pkill -STOP -f netmgrd
pkill -STOP -f qmipriod
pkill -STOP -f ATFWD-daemon
pkill -STOP -f "vendor.dpmd"
pkill -STOP -f dpmQmiMgr
pkill -STOP -f qms
pkill -STOP -f port-bridge
pkill -STOP -f adpl
pkill -STOP -f qti
pkill -STOP -f "gnss-aidl"
pkill -STOP -f xtra-daemon
pkill -STOP -f edgnss
pkill -STOP -f loc_launcher
pkill -STOP -f lowi-server
pkill -STOP -f "sensors-service"
pkill -STOP -f "sensors.qti"
pkill -STOP -f sensor-notifier
pkill -STOP -f fingerprint
pkill -STOP -f "vibrator.service"
pkill -STOP -f vppservice
pkill -STOP -f drmserver
pkill -STOP -f "drm@"
pkill -STOP -f "drm-service"
pkill -STOP -f wifidisplay
pkill -STOP -f wfdvndservice
pkill -STOP -f wfdhdcphalservice
pkill -STOP -f "vendor.lineage.touch"
pkill -STOP -f "vendor.lineage.powershare"
pkill -STOP -f ssgtzd
pkill -STOP -f ssgqmigd
pkill -STOP -f mlipayd
pkill -STOP -f mlid
pkill -STOP -f qcc-trd
pkill -STOP -f qccsyshal
pkill -STOP -f qconfigservice
pkill -STOP -f "capabilityconfigstore"
pkill -STOP -f dspservice
pkill -STOP -f qspmhal
pkill -STOP -f tcmd
pkill -STOP -f sscrpcd
pkill -STOP -f adsprpcd
pkill -STOP -f cdsprpcd
pkill -STOP -f audioadsprpcd
pkill -STOP -f update_engine
pkill -STOP -f incidentd
pkill -STOP -f traced
pkill -STOP -f traced_probes
pkill -STOP -f storaged
pkill -STOP -f installd
pkill -STOP -f tombstoned
pkill -STOP -f "nfc-service"
pkill -STOP -f "bluetooth@"
pkill -STOP -f "ir-service"
pkill -STOP -f "usb-service"
pkill -STOP -f "usb.gadget"

echo "🧹 [4/8] Clearing memory cache..."
echo 3 > /proc/sys/vm/drop_caches

echo "🔋 [5/8] Starting battery daemon..."
kill $(cat /data/local/tmp/zeus_battery.pid 2>/dev/null) 2>/dev/null
sh /data/local/tmp/zeus_battery.sh &
sleep 2

echo "💨 [6/8] Starting cooler daemon..."
kill $(cat /data/local/tmp/zeus_cooler.pid 2>/dev/null) 2>/dev/null
sh /data/local/tmp/zeus_cooler.sh &
sleep 1

echo "🛡 [7/8] Starting watchdog..."
kill $(cat /data/local/tmp/zeus_watchdog.pid 2>/dev/null) 2>/dev/null
nohup sh /data/local/tmp/zeus_watchdog_loop.sh > /dev/null 2>&1 &
sleep 1

echo "✅ [8/8] Verification..."
echo ""
ip addr show $IFACE | grep "inet "
ping -c 1 -W 2 $GATEWAY > /dev/null 2>&1 && echo "   Gateway: OK" || echo "   Gateway: FAIL"
ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1 && echo "   Internet: OK" || echo "   Internet: FAIL"
SOC=$(cat /sys/class/power_supply/battery/capacity)
CPU_T=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
echo "   Battery: ${SOC}%"
echo "   CPU temp: ${CPU_T}C"
echo ""
free -m
echo ""

echo "📱 Switching adb to TCP (connection will drop)..."
setprop service.adb.tcp.port 5555
stop adbd
start adbd

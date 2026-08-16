#!/usr/bin/env bash
BASE="$HOME/wireless-inventory"
DATA="$BASE/data"
LOG="$BASE/logs/inventory.log"
mkdir -p "$DATA"/{csv,json,pcap} "$BASE/logs"
cleanup() {
    echo
    echo "[+] Stopping inventory..."
    pkill -TERM -f "ubertooth-rx" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM
detect_hardware() {
    WIFI="OFF"
    UBERTOOTH="OFF"
    ZIGBEE="OFF"
    if iw dev 2>/dev/null | grep -q Interface; then
        WIFI="ONLINE"
    fi
    if command -v ubertooth-util >/dev/null 2>&1; then
        if ubertooth-util -v >/dev/null 2>&1; then
            UBERTOOTH="ONLINE"
        fi
    fi
    if lsusb 2>/dev/null | grep -Ei \
        'nRF52840|CC2531|KW41|802.15.4|Zigbee' >/dev/null; then
        ZIGBEE="POSSIBLE"
    fi
}
show_menu() {
    clear
    echo "======================================================"
    echo "          WIRELESS HARDWARE INVENTORY"
    echo "======================================================"
    echo
    echo " Wi-Fi       : $WIFI"
    echo " Ubertooth   : $UBERTOOTH"
    echo " Zigbee      : $ZIGBEE"
    echo
    echo "------------------------------------------------------"
    echo
    echo " 1  Wi-Fi discovery"
    echo " 2  Bluetooth/BLE discovery"
    echo " 3  Zigbee/802.15.4 status"
    echo " 4  Combined hardware inventory"
    echo " 5  USB hardware"
    echo " 6  Export inventory"
    echo " 7  Continuous monitoring"
    echo " q  Quit"
    echo
    echo "======================================================"
}
wifi_scan() {
    echo
    echo "[+] Wi-Fi interfaces:"
    iw dev
    echo
    echo "[+] Nearby Wi-Fi networks:"
    echo
    sudo iw dev 2>/dev/null |
        awk '$1=="Interface"{print $2}' |
        while read -r IFACE; do
            echo "Scanning $IFACE..."
            sudo iw dev "$IFACE" scan 2>/dev/null |
                grep -E \
                'BSS |SSID:|signal:|freq:|DS Parameter set: channel' |
                tee -a "$LOG"
        done
    read -rp "Press ENTER..."
}
bluetooth_scan() {
    echo
    echo "[+] Bluetooth adapters:"
    bluetoothctl list
    echo
    echo "[+] Bluetooth discovery:"
    echo
    bluetoothctl <<EOF
power on
scan on
EOF
    sleep 15
    bluetoothctl devices
    echo
    read -rp "Press ENTER to stop discovery..."
    bluetoothctl scan off
}
zigbee_status() {
    echo
    echo "======================================================"
    echo "             ZIGBEE / 802.15.4 STATUS"
    echo "======================================================"
    echo
    echo "[+] USB hardware:"
    lsusb
    echo
    echo "[+] Serial interfaces:"
    ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true
    echo
    echo "[+] Kismet Zigbee capture drivers:"
    for DRIVER in \
        kismet_cap_nrf_52840 \
        kismet_cap_ti_cc_2531 \
        kismet_cap_nxp_kw41z \
        kismet_cap_rz_killerbee
    do
        if command -v "$DRIVER" >/dev/null 2>&1; then
            echo "  [+] $DRIVER"
        else
            echo "  [-] $DRIVER"
        fi
    done
    echo
    echo "A Wi-Fi adapter or Ubertooth alone is NOT treated"
    echo "as a Zigbee adapter."
    echo
    read -rp "Press ENTER..."
}
usb_inventory() {
    clear
    echo "======================================================"
    echo "                 USB HARDWARE"
    echo "======================================================"
    echo
    lsusb
    echo
    echo "Detailed USB information:"
    echo
    if command -v usb-devices >/dev/null 2>&1; then
        usb-devices
    fi
    read -rp "Press ENTER..."
}
combined_inventory() {
    clear
    echo "======================================================"
    echo "             COMBINED INVENTORY"
    echo "======================================================"
    echo
    echo "Timestamp: $(date)"
    echo
    echo "--- Wi-Fi ---"
    iw dev 2>/dev/null |
        grep -E 'Interface|type'
    echo
    echo "--- Bluetooth ---"
    bluetoothctl list 2>/dev/null
    echo
    echo "--- USB / Zigbee hardware ---"
    lsusb 2>/dev/null |
        grep -Ei \
        'Zigbee|802.15.4|nRF52840|CC2531|KW41|Ubertooth|Wireless|Bluetooth' \
        || echo "No matching hardware detected."
    echo
    echo "--- Ubertooth ---"
    if command -v ubertooth-util >/dev/null 2>&1; then
        ubertooth-util -v 2>/dev/null || true
    fi
    read -rp "Press ENTER..."
}
export_inventory() {
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    OUT="$DATA/json/inventory_$TIMESTAMP.json"
    python3 - "$OUT" <<'PY'
import json
import subprocess
import sys
from datetime import datetime
out = sys.argv[1]
def run(cmd):
    try:
        return subprocess.check_output(
            cmd,
            shell=True,
            text=True,
            stderr=subprocess.DEVNULL
        ).strip()
    except:
        return ""
data = {
    "timestamp": datetime.now().isoformat(),
    "wifi": run("iw dev"),
    "bluetooth": run("bluetoothctl list"),
    "usb": run("lsusb"),
    "serial": run("ls -l /dev/ttyUSB* /dev/ttyACM*")
}
with open(out, "w") as f:
    json.dump(data, f, indent=2)
print(out)
PY
    echo
    echo "[+] Inventory exported:"
    echo "    $OUT"
    read -rp "Press ENTER..."
}
continuous() {
    echo
    echo "[+] Continuous monitoring."
    echo "[+] Press Ctrl+C to stop."
    echo
    while true; do
        detect_hardware
        clear
        echo "======================================================"
        echo "          LIVE WIRELESS INVENTORY"
        echo "======================================================"
        echo
        echo "Time: $(date)"
        echo
        echo "Wi-Fi       : $WIFI"
        echo "Ubertooth   : $UBERTOOTH"
        echo "Zigbee      : $ZIGBEE"
        echo
        echo "--- USB ---"
        lsusb
        echo
        echo "--- Bluetooth adapters ---"
        bluetoothctl list 2>/dev/null
        echo
        echo "--- Wi-Fi interfaces ---"
        iw dev 2>/dev/null
        sleep 5
    done
}
while true; do
    detect_hardware
    show_menu
    read -rp "Select: " OPTION
    case "$OPTION" in
        1) wifi_scan ;;
        2) bluetooth_scan ;;
        3) zigbee_status ;;
        4) combined_inventory ;;
        5) usb_inventory ;;
        6) export_inventory ;;
        7) continuous ;;
        q|Q) cleanup ;;
        *)
            echo "Invalid option."
            sleep 1
            ;;
    esac
done

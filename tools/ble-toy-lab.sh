#!/bin/bash
set -e
APP="/root/shadowhacker/tools/ble_toy_lab.py"
echo "======================================"
echo "       BLE TOY LAB - KALI"
echo "======================================"
if ! command -v bluetoothctl >/dev/null 2>&1; then
    echo "[!] BlueZ is not installed."
    echo "    Run:"
    echo "    sudo apt install bluez bluetooth"
    exit 1
fi
sudo rfkill unblock bluetooth 2>/dev/null || true
sudo systemctl start bluetooth 2>/dev/null || true
echo
echo "[+] Bluetooth adapter:"
bluetoothctl list
echo
echo "[+] Starting BLE Toy Lab..."
echo
exec python3 "$APP"

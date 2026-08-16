#!/usr/bin/env bash
#
# hidden-ssid-scanner.sh
# Passive hidden Wi-Fi SSID discovery for authorised networks
#
set -e
OUTDIR="$HOME/hidden-ssid-scans/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
cleanup() {
    echo
    echo "[+] Stopping scanner..."
    if [[ -n "${MON:-}" ]]; then
        sudo airmon-ng stop "$MON" >/dev/null 2>&1 || true
    fi
    sudo systemctl restart NetworkManager >/dev/null 2>&1 || true
    echo "[+] Captures saved to:"
    echo "    $OUTDIR"
}
trap cleanup EXIT INT TERM
echo "=========================================="
echo "       PASSIVE HIDDEN SSID SCANNER"
echo "=========================================="
echo
# Find wireless interfaces
mapfile -t IFACES < <(
    iw dev 2>/dev/null |
    awk '$1=="Interface"{print $2}'
)
if [[ ${#IFACES[@]} -eq 0 ]]; then
    echo "[!] No Wi-Fi interface detected."
    echo
    echo "Check with:"
    echo "    iw dev"
    exit 1
fi
echo "Wireless interfaces:"
echo
for i in "${!IFACES[@]}"; do
    echo "  [$i] ${IFACES[$i]}"
done
echo
read -rp "Select interface [0]: " IDX
IDX="${IDX:-0}"
IFACE="${IFACES[$IDX]}"
if [[ -z "$IFACE" ]]; then
    echo "[!] Invalid interface."
    exit 1
fi
echo
echo "[+] Selected: $IFACE"
echo "[+] Output:   $OUTDIR"
echo
# Stop processes that interfere with monitor mode
sudo airmon-ng check kill >/dev/null 2>&1 || true
echo "[+] Enabling monitor mode..."
sudo airmon-ng start "$IFACE"
# Usually wlan0 -> wlan0mon
MON="${IFACE}mon"
# Verify monitor interface
if ! iw dev | grep -q "Interface $MON"; then
    echo "[!] Could not find $MON."
    echo
    echo "Available interfaces:"
    iw dev
    exit 1
fi
echo "[+] Monitor interface: $MON"
echo
echo "[+] Starting passive scan..."
echo
echo "Hidden networks may appear as:"
echo
echo "    <length: 0>"
echo "    <hidden>"
echo
echo "A hidden SSID may become visible when a legitimate"
echo "client naturally reveals the network name."
echo
echo "Press Ctrl+C to stop."
echo
sudo airodump-ng \
    --band abg \
    --write "$OUTDIR/capture" \
    --output-format csv,pcap \
    "$MON"

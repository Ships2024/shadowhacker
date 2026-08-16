#!/bin/bash
# ─────────────────────────────────────────────────────────
#  Smart TV Bluetooth Discovery Tool
#  Part of Shadow Hacker | Ships2024
#  Scans for Smart TVs via Bluetooth using OUI fingerprinting,
#  device class parsing, and service UUID matching.
# ─────────────────────────────────────────────────────────

YS="\e[1;33m"
CE="\e[0m"
RS="\e[1;31m"
GN="\e[1;32m"
CY="\e[1;36m"
BS="\e[0;34m"
LGYS="\e[0;37m"

SCAN_SECONDS=20
LOG=/tmp/smarttv_scan_$$.log
RESULTS=/tmp/smarttv_results_$$.txt
> "$RESULTS"

# ── Known Smart TV Bluetooth OUI prefixes ────────────────
declare -A TV_OUI
# Samsung
TV_OUI["00:15:99"]="Samsung (TV)"
TV_OUI["04:18:D6"]="Samsung (TV)"
TV_OUI["08:D4:2B"]="Samsung (TV)"
TV_OUI["78:BD:BC"]="Samsung (TV)"
TV_OUI["A4:02:B9"]="Samsung (TV)"
TV_OUI["8C:77:12"]="Samsung (TV)"
TV_OUI["CC:07:AB"]="Samsung (TV)"
TV_OUI["F8:04:2E"]="Samsung (TV)"
TV_OUI["BC:72:B1"]="Samsung (TV)"
TV_OUI["34:C3:AC"]="Samsung (TV)"
TV_OUI["FC:DB:B3"]="Samsung (TV)"
TV_OUI["7C:64:56"]="Samsung (TV)"
TV_OUI["50:85:69"]="Samsung (TV)"
TV_OUI["18:54:CF"]="Samsung (TV)"
# LG
TV_OUI["A8:91:3D"]="LG (TV)"
TV_OUI["00:E0:91"]="LG (TV)"
TV_OUI["34:DF:2A"]="LG (TV)"
TV_OUI["88:C9:D0"]="LG (TV)"
TV_OUI["B4:E6:2A"]="LG (TV)"
TV_OUI["78:5D:C8"]="LG (TV)"
TV_OUI["C4:36:6C"]="LG (TV)"
# Sony
TV_OUI["00:13:A9"]="Sony (TV)"
TV_OUI["7C:C7:09"]="Sony (TV)"
TV_OUI["AC:9B:0A"]="Sony (TV)"
TV_OUI["10:4F:A8"]="Sony (TV)"
TV_OUI["04:CB:88"]="Sony (TV)"
TV_OUI["18:00:2D"]="Sony (TV)"
TV_OUI["FC:0F:E6"]="Sony (TV)"
# Philips / TPVision
TV_OUI["00:17:88"]="Philips (TV)"
TV_OUI["D0:57:7B"]="Philips (TV)"
TV_OUI["EC:B5:FA"]="Philips (TV)"
# Hisense
TV_OUI["00:17:C2"]="Hisense (TV)"
TV_OUI["14:A3:64"]="Hisense (TV)"
TV_OUI["2C:FD:A1"]="Hisense (TV)"
TV_OUI["C4:9D:ED"]="Hisense (TV)"
# TCL
TV_OUI["CC:2D:B7"]="TCL (TV)"
TV_OUI["DC:53:7C"]="TCL (TV)"
TV_OUI["F4:8E:38"]="TCL (TV)"
# Vizio
TV_OUI["00:19:8F"]="Vizio (TV)"
TV_OUI["58:EF:68"]="Vizio (TV)"
TV_OUI["C4:F5:7A"]="Vizio (TV)"
# Panasonic
TV_OUI["00:80:F0"]="Panasonic (TV)"
TV_OUI["34:49:5B"]="Panasonic (TV)"
TV_OUI["28:24:FF"]="Panasonic (TV)"
# Sharp
TV_OUI["00:08:22"]="Sharp (TV)"
TV_OUI["00:21:E7"]="Sharp (TV)"
# Toshiba
TV_OUI["00:0A:79"]="Toshiba (TV)"
TV_OUI["E8:E0:B7"]="Toshiba (TV)"
# Roku
TV_OUI["AC:3A:7A"]="Roku (Smart TV)"
TV_OUI["D4:E2:2F"]="Roku (Smart TV)"
TV_OUI["CC:6D:A0"]="Roku (Smart TV)"
# Apple TV
TV_OUI["A4:D9:31"]="Apple TV"
TV_OUI["98:01:A7"]="Apple TV"
TV_OUI["F0:99:BF"]="Apple TV"
# Chromecast / Google
TV_OUI["F4:F5:D8"]="Chromecast/Google TV"
TV_OUI["00:1A:11"]="Google TV"
TV_OUI["54:60:09"]="Chromecast"
# Amazon Fire TV
TV_OUI["FC:65:DE"]="Amazon Fire TV"
TV_OUI["44:65:0D"]="Amazon Fire TV"
TV_OUI["68:37:E9"]="Amazon Fire TV"
# Nvidia Shield
TV_OUI["00:04:4B"]="Nvidia Shield TV"

# ── TV device class bitmask check ────────────────────────
# Major class 4 = Audio/Video (bits 10-12 = 0100)
# Minor classes that indicate a TV/display: 0xBC, 0x3C, 0x4C
is_tv_class() {
    local class_hex="$1"
    if [[ -z "$class_hex" || "$class_hex" == "0x000000" ]]; then return 1; fi
    local class_dec=$(( 16#${class_hex#0x} ))
    local major=$(( (class_dec >> 8) & 0x1F ))
    local minor=$(( (class_dec >> 2) & 0x3F ))
    # Major class 4 = Audio/Video
    if [[ "$major" -eq 4 ]]; then
        # Minor 0x0F=Video display+speaker (TV), 0x0B=VCR, 0x09=Set-top box
        if [[ "$minor" -eq 15 || "$minor" -eq 9 || "$minor" -eq 11 ]]; then
            return 0
        fi
    fi
    return 1
}

# ── UUID check for TV-related services ───────────────────
is_tv_uuid() {
    local uuids="$1"
    # AV Remote Control (0x110E), AV Remote Control Target (0x110C),
    # Audio Sink (0x110B), Video Source (0x1303), Video Sink (0x1304)
    echo "$uuids" | grep -qiE '110[BCE]|1303|1304'
}

# ── UI ───────────────────────────────────────────────────
clear
printf '\033[8;40;95t'
echo -e "${YS}Smart TV Bluetooth Discovery${CE}"
echo -e "${LGYS}────────────────────────────────────────────────${CE}"
echo -e "Adapter auto-detect..."

ADAPTER=$(hciconfig 2>/dev/null | grep -o 'hci[0-9]' | head -1)
[[ -z "$ADAPTER" ]] && ADAPTER="hci0"

# Bring adapter up if needed
hciconfig "$ADAPTER" up 2>/dev/null
if ! hciconfig "$ADAPTER" 2>/dev/null | grep -q "UP"; then
    echo -e "${RS}Bluetooth adapter $ADAPTER not available.${CE}"
    echo -e "Check: ${YS}hciconfig -a${CE}"
    exit 1
fi

echo -e "Adapter : ${YS}$ADAPTER${CE}"
echo -e "Scan    : ${YS}${SCAN_SECONDS}s${CE}"
echo -e ""
echo -e "${BS}Scanning for Bluetooth devices...${CE}"
echo -e "${LGYS}(Classic BT + BLE)${CE}"
echo -e ""

# ── Run scan ─────────────────────────────────────────────
# Classic scan via bluetoothctl
{
    echo "scan on"
    sleep "$SCAN_SECONDS"
    echo "scan off"
    echo "quit"
} | bluetoothctl 2>/dev/null | grep -oP '([0-9A-F]{2}:){5}[0-9A-F]{2}' | sort -u > "$LOG"

# Also try hcitool scan (classic) as fallback
hcitool scan 2>/dev/null | grep -oP '([0-9A-F]{2}:){5}[0-9A-F]{2}' >> "$LOG"
hcitool lescan --passive 2>/dev/null &
LESCAN_PID=$!
sleep 5
kill $LESCAN_PID 2>/dev/null
cat /tmp/hcitool_le_$$.tmp 2>/dev/null >> "$LOG"

sort -u "$LOG" -o "$LOG"
TOTAL=$(wc -l < "$LOG")
echo -e "${GN}Scan complete. ${TOTAL} device(s) found.${CE}"
echo -e "${YS}Analysing for Smart TVs...${CE}\n"

FOUND=0

while IFS= read -r MAC; do
    [[ -z "$MAC" ]] && continue

    # Get OUI (first 3 octets, uppercase)
    OUI=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | cut -d: -f1-3)
    LABEL=""

    # 1 — OUI match
    for KEY in "${!TV_OUI[@]}"; do
        KEY_UPPER=$(echo "$KEY" | tr '[:lower:]' '[:upper:]')
        if [[ "$OUI" == "$KEY_UPPER" ]]; then
            LABEL="${TV_OUI[$KEY]}"
            break
        fi
    done

    # 2 — Device class match (bluetoothctl info)
    INFO=$(bluetoothctl info "$MAC" 2>/dev/null)
    NAME=$(echo "$INFO" | grep -i "Name:" | awk -F': ' '{print $2}' | head -1)
    CLASS=$(echo "$INFO" | grep -i "Class:" | awk '{print $2}' | head -1)
    UUIDS=$(echo "$INFO" | grep -A100 "UUID" | grep -oE '0x[0-9A-Fa-f]{4}')

    if [[ -z "$LABEL" ]]; then
        is_tv_class "$CLASS" && LABEL="Smart TV (by device class)"
    fi
    if [[ -z "$LABEL" ]]; then
        is_tv_uuid "$UUIDS" && LABEL="Smart TV (by AV service UUID)"
    fi

    # 3 — Name heuristic
    if [[ -z "$LABEL" && -n "$NAME" ]]; then
        echo "$NAME" | grep -qiE 'tv|television|bravia|oled|qled|nanocell|fire tv|shield|chromecast|roku|smartcast|webos|tizen' \
            && LABEL="Smart TV (by device name)"
    fi

    if [[ -n "$LABEL" ]]; then
        FOUND=$((FOUND + 1))
        DISPLAY_NAME="${NAME:-Unknown}"
        echo -e "${GN}[+]${CE} ${YS}${MAC}${CE}"
        echo -e "    Name  : ${CY}${DISPLAY_NAME}${CE}"
        echo -e "    Type  : ${GN}${LABEL}${CE}"
        [[ -n "$CLASS" ]] && echo -e "    Class : $CLASS"
        echo -e "    OUI   : $OUI"
        echo ""
        echo "$MAC | $DISPLAY_NAME | $LABEL | $OUI" >> "$RESULTS"
    fi
done < "$LOG"

# ── Summary ──────────────────────────────────────────────
echo -e "${LGYS}────────────────────────────────────────────────${CE}"
if [[ "$FOUND" -eq 0 ]]; then
    echo -e "${RS}No Smart TVs detected.${CE}"
    echo -e "Tips:"
    echo -e "  • Ensure the TV's Bluetooth is enabled / discoverable"
    echo -e "  • Run again with the TV in pairing/standby mode"
    echo -e "  • Move closer to the target device"
else
    echo -e "${GN}${FOUND} Smart TV(s) detected.${CE}"
    echo -e "Results saved to: ${YS}$RESULTS${CE}"
fi
echo -e ""

# Cleanup
rm -f "$LOG"

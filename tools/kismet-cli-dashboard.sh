#!/usr/bin/env bash
#
# kismet-cli-dashboard.sh
#
# Interactive Kismet CLI controller/dashboard
#
# Controls:
#   M = enable monitor mode
#   N = return to managed mode
#   S = start Kismet
#   X = stop Kismet
#   E = export current results
#   L = list saved sessions
#   R = refresh
#   Q = quit
#
# Results:
#   ~/kismet-results/YYYY-MM-DD_HH-MM-SS/
#
#   devices.json
#   devices.csv
#   gps.json
#   summary.txt
#   kismet.log
#
# Requirements:
#   kismet
#   iw
#   curl
#   jq
#
# Run:
#   chmod +x kismet-cli-dashboard.sh
#   ./kismet-cli-dashboard.sh
#
# Use only on networks and radio equipment you own or are
# explicitly authorized to monitor.
#
set -u
set -o pipefail
KISMET_URL="${KISMET_URL:-http://127.0.0.1:2501}"
RESULT_ROOT="${RESULT_ROOT:-$HOME/kismet-results}"
REFRESH="${REFRESH:-2}"
INTERFACE=""
SESSION_DIR=""
KISMET_PID=""
RUNNING=0
mkdir -p "$RESULT_ROOT"
# ============================================================
# Cleanup
# ============================================================
cleanup() {
    printf '\033[?25h'
    if [[ -n "${KISMET_PID:-}" ]] &&
       kill -0 "$KISMET_PID" 2>/dev/null; then
        echo
        echo "[+] Stopping Kismet..."
        sudo kill "$KISMET_PID" 2>/dev/null || true
        sleep 1
    fi
    exit 0
}
trap cleanup INT TERM
# ============================================================
# Dependency check
# ============================================================
check_dependencies() {
    local missing=()
    for cmd in kismet iw curl jq awk sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} )); then
        echo "Missing dependencies:"
        printf '  %s\n' "${missing[@]}"
        echo
        echo "On Kali/Debian:"
        echo "  sudo apt install kismet iw curl jq"
        exit 1
    fi
}
# ============================================================
# Wireless interface detection
# ============================================================
detect_interface() {
    INTERFACE="$(
        iw dev 2>/dev/null |
        awk '$1=="Interface"{print $2; exit}'
    )"
    if [[ -z "$INTERFACE" ]]; then
        echo "[-] No wireless interface detected."
        exit 1
    fi
}
# ============================================================
# Interface state
# ============================================================
interface_state() {
    iw dev "$INTERFACE" info 2>/dev/null |
        awk '$1=="type"{print $2; exit}'
}
# ============================================================
# Monitor mode
# ============================================================
enable_monitor() {
    clear
    echo "=============================================="
    echo " ENABLE MONITOR MODE"
    echo "=============================================="
    echo
    echo "Interface: $INTERFACE"
    echo
    if [[ "$(interface_state)" == "monitor" ]]; then
        echo "[+] Already in monitor mode."
        sleep 2
        return
    fi
    echo "[+] Bringing interface down..."
    sudo ip link set "$INTERFACE" down || {
        echo "[-] Failed to bring interface down."
        sleep 2
        return
    }
    echo "[+] Setting monitor mode..."
    sudo iw dev "$INTERFACE" set type monitor || {
        echo "[-] Failed to enable monitor mode."
        sudo ip link set "$INTERFACE" up 2>/dev/null || true
        sleep 2
        return
    }
    echo "[+] Bringing interface up..."
    sudo ip link set "$INTERFACE" up || true
    sleep 2
    echo
    if [[ "$(interface_state)" == "monitor" ]]; then
        echo "[+] Monitor mode ENABLED."
    else
        echo "[-] Monitor mode could not be confirmed."
    fi
    sleep 2
}
# ============================================================
# Managed mode
# ============================================================
disable_monitor() {
    clear
    echo "=============================================="
    echo " DISABLE MONITOR MODE"
    echo "=============================================="
    echo
    if [[ "$(interface_state)" == "managed" ]]; then
        echo "[+] Already in managed mode."
        sleep 2
        return
    fi
    echo "[+] Bringing interface down..."
    sudo ip link set "$INTERFACE" down || true
    echo "[+] Returning to managed mode..."
    sudo iw dev "$INTERFACE" set type managed || {
        echo "[-] Failed to restore managed mode."
        sudo ip link set "$INTERFACE" up 2>/dev/null || true
        sleep 2
        return
    }
    sudo ip link set "$INTERFACE" up || true
    sleep 2
    echo "[+] Managed mode restored."
    sleep 2
}
# ============================================================
# Create session
# ============================================================
create_session() {
    if [[ -n "$SESSION_DIR" ]]; then
        return
    fi
    SESSION_DIR="$RESULT_ROOT/$(date '+%Y-%m-%d_%H-%M-%S')"
    mkdir -p "$SESSION_DIR"
    {
        echo "KISMET SESSION"
        echo "==============="
        echo "Started: $(date)"
        echo "Interface: $INTERFACE"
        echo "Kismet URL: $KISMET_URL"
        echo
    } > "$SESSION_DIR/summary.txt"
}
# ============================================================
# Start Kismet
# ============================================================
start_kismet() {
    clear
    echo "=============================================="
    echo " START KISMET"
    echo "=============================================="
    echo
    if [[ "$RUNNING" == "1" ]]; then
        echo "[+] Kismet is already running."
        sleep 2
        return
    fi
    create_session
    echo "[+] Session:"
    echo "    $SESSION_DIR"
    echo
    echo "[+] Interface:"
    echo "    $INTERFACE"
    echo
    echo "[+] Starting Kismet..."
    sudo kismet \
        --no-ncurses \
        > "$SESSION_DIR/kismet.log" 2>&1 &
    KISMET_PID=$!
    echo "$KISMET_PID" > "$SESSION_DIR/kismet.pid"
    echo
    echo "[+] Waiting for Kismet API..."
    local attempts=0
    while (( attempts < 15 )); do
        if curl -fsS \
            --max-time 1 \
            "$KISMET_URL/system/status.json" \
            >/dev/null 2>&1; then
            RUNNING=1
            echo "[+] Kismet API is online."
            sleep 2
            return
        fi
        sleep 1
        ((attempts++))
    done
    echo "[-] Kismet API did not respond."
    echo "    Check:"
    echo "    $SESSION_DIR/kismet.log"
    RUNNING=0
    sleep 3
}
# ============================================================
# Stop Kismet
# ============================================================
stop_kismet() {
    clear
    echo "=============================================="
    echo " STOP KISMET"
    echo "=============================================="
    echo
    if [[ "$RUNNING" != "1" ]]; then
        echo "[+] Kismet is not running."
        sleep 2
        return
    fi
    if [[ -n "$KISMET_PID" ]]; then
        echo "[+] Stopping PID $KISMET_PID..."
        sudo kill "$KISMET_PID" 2>/dev/null || true
        sleep 3
        if kill -0 "$KISMET_PID" 2>/dev/null; then
            sudo kill -9 "$KISMET_PID" 2>/dev/null || true
        fi
    fi
    KISMET_PID=""
    RUNNING=0
    if [[ -n "$SESSION_DIR" ]]; then
        echo "Stopped: $(date)" >> "$SESSION_DIR/summary.txt"
    fi
    echo "[+] Kismet stopped."
    sleep 2
}
# ============================================================
# Kismet API
# ============================================================
api_get() {
    curl \
        -fsS \
        --max-time 3 \
        "$KISMET_URL/$1" \
        2>/dev/null
}
# ============================================================
# Export results
# ============================================================
export_results() {
    clear
    echo "=============================================="
    echo " EXPORT KISMET RESULTS"
    echo "=============================================="
    echo
    if [[ -z "$SESSION_DIR" ]]; then
        create_session
    fi
    echo "[+] Export directory:"
    echo "    $SESSION_DIR"
    echo
    DEVICES="$(api_get "devices/all_devices.json")"
    if [[ -z "$DEVICES" ]]; then
        echo "[-] Kismet API unavailable."
        echo
        echo "The Kismet log remains available at:"
        echo "$SESSION_DIR/kismet.log"
        sleep 3
        return
    fi
    printf '%s\n' "$DEVICES" \
        > "$SESSION_DIR/devices.json"
    {
        echo "MAC,SSID,Channel,Frequency,Security,Signal,Packets,Manufacturer"
        jq -r '
            .[]
            |
            [
                (.kismet.device.base.mac // ""),
                (.kismet.device.base.name // ""),
                (.kismet.device.base.channel // ""),
                (.kismet.device.base.frequency // ""),
                (.kismet.device.base.crypt // ""),
                (
                    .kismet.device.base.signal.device.rssi
                    // .kismet.device.base.signal.rssi
                    // ""
                ),
                (
                    .kismet.device.base.packets.total
                    // 0
                ),
                (.kismet.device.base.manuf // "")
            ]
            | @csv
        ' <<< "$DEVICES"
    } > "$SESSION_DIR/devices.csv"
    GPS="$(api_get "system/status.json")"
    if [[ -n "$GPS" ]]; then
        printf '%s\n' "$GPS" \
            > "$SESSION_DIR/gps.json"
    fi
    DEVICE_COUNT="$(
        jq 'length' <<< "$DEVICES" 2>/dev/null || echo 0
    )"
    {
        echo
        echo "EXPORT"
        echo "======"
        echo "Exported: $(date)"
        echo "Interface: $INTERFACE"
        echo "Devices: $DEVICE_COUNT"
    } >> "$SESSION_DIR/summary.txt"
    date '+%Y-%m-%d %H:%M:%S' \
        > "$SESSION_DIR/exported.txt"
    echo
    echo "[+] EXPORT COMPLETE"
    echo
    echo "Files: devices.json  devices.csv  gps.json  summary.txt  kismet.log"
    echo
    sleep 4
}
# ============================================================
# List sessions
# ============================================================
list_results() {
    clear
    echo "=============================================="
    echo " SAVED KISMET SESSIONS"
    echo "=============================================="
    echo
    if [[ ! -d "$RESULT_ROOT" ]]; then
        echo "No results directory."
        sleep 2
        return
    fi
    mapfile -t SESSIONS < <(
        find "$RESULT_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' |
        sort -r
    )
    if (( ${#SESSIONS[@]} == 0 )); then
        echo "No saved sessions."
    else
        printf '%s\n' "${SESSIONS[@]}"
    fi
    echo
    echo "Location: $RESULT_ROOT"
    sleep 4
}
# ============================================================
# Dashboard
# ============================================================
draw_dashboard() {
    clear
    printf '\033[?25l'
    echo "╔══════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         KISMET CLI MONITOR                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════╝"
    echo
    printf " Interface : %-18s\n" "$INTERFACE"
    printf " Mode      : %-18s\n" "$(interface_state)"
    if [[ "$RUNNING" == "1" ]]; then
        printf " Kismet    : %-18s\n" "RUNNING"
    else
        printf " Kismet    : %-18s\n" "STOPPED"
    fi
    printf " Time      : %-18s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "$SESSION_DIR" ]]; then
        printf " Session   : %s\n" "$SESSION_DIR"
    else
        printf " Session   : none\n"
    fi
    echo
    echo "──────────────────────────────────────────────────────────────────────────────────"
    GPS="$(api_get "system/status.json")"
    echo " GPS"
    if [[ -n "$GPS" ]]; then
        LAT="$(jq -r '.kismet.system.gps.lat // .kismet.system.gps.latitude // "N/A"' <<< "$GPS" 2>/dev/null)"
        LON="$(jq -r '.kismet.system.gps.lon // .kismet.system.gps.longitude // "N/A"' <<< "$GPS" 2>/dev/null)"
        ALT="$(jq -r '.kismet.system.gps.alt // .kismet.system.gps.altitude // "N/A"' <<< "$GPS" 2>/dev/null)"
        FIX="$(jq -r '.kismet.system.gps.fix // .kismet.system.gps.fix_type // "N/A"' <<< "$GPS" 2>/dev/null)"
        SATS="$(jq -r '.kismet.system.gps.satellites // .kismet.system.gps.sats // "N/A"' <<< "$GPS" 2>/dev/null)"
        printf " Latitude : %-18s Longitude: %-18s\n" "$LAT" "$LON"
        printf " Altitude : %-18s Fix: %-12s Satellites: %s\n" "$ALT" "$FIX" "$SATS"
    else
        echo " Kismet GPS information unavailable."
    fi
    echo
    echo "──────────────────────────────────────────────────────────────────────────────────"
    JSON="$(api_get "devices/all_devices.json")"
    if [[ -z "$JSON" ]]; then
        echo
        echo " Kismet API unavailable."
        echo
    else
        COUNT="$(jq 'length' <<< "$JSON" 2>/dev/null || echo 0)"
        echo
        echo " DISCOVERED DEVICES: $COUNT"
        echo
        printf "%-18s %-23s %-5s %-12s %-8s %-9s %-18s\n" \
            "MAC" "SSID" "CH" "SECURITY" "SIGNAL" "PACKETS" "MANUFACTURER"
        echo "──────────────────────────────────────────────────────────────────────────────────"
        jq -r '
            .[] |
            [
                (.kismet.device.base.mac // "?"),
                (.kismet.device.base.name // "<hidden>"),
                (.kismet.device.base.channel // "?"),
                (.kismet.device.base.crypt // "?"),
                (.kismet.device.base.signal.device.rssi // .kismet.device.base.signal.rssi // "?"),
                (.kismet.device.base.packets.total // 0),
                (.kismet.device.base.manuf // "Unknown")
            ] | @tsv
        ' <<< "$JSON" 2>/dev/null |
        head -30 |
        while IFS=$'\t' read -r MAC SSID CHANNEL SECURITY SIGNAL PACKETS MANUFACTURER; do
            printf "%-18s %-23.23s %-5s %-12.12s %-8s %-9s %-18.18s\n" \
                "$MAC" "$SSID" "$CHANNEL" "$SECURITY" "$SIGNAL" "$PACKETS" "$MANUFACTURER"
        done
    fi
    echo
    echo "──────────────────────────────────────────────────────────────────────────────────"
    echo
    echo " [M] Monitor mode  [N] Managed mode  [S] Start Kismet  [X] Stop Kismet"
    echo " [E] Export        [L] Saved sessions [R] Refresh       [Q] Quit"
    echo
    printf " Command: "
}
# ============================================================
# Main
# ============================================================
check_dependencies
detect_interface
while true; do
    draw_dashboard
    IFS= read -r -n 1 KEY
    case "$KEY" in
        m|M) enable_monitor ;;
        n|N) disable_monitor ;;
        s|S) start_kismet ;;
        x|X) stop_kismet ;;
        e|E) export_results ;;
        l|L) list_results ;;
        r|R) ;;
        q|Q) cleanup ;;
    esac
done

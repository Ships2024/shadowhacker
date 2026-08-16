#!/usr/bin/env bash
#
# WardriveScanner
# Passive multi-card Wi-Fi discovery + GPS tracking
#
# Views:
#   LIVE       AP discovery
#   GPS        GPS information
#   STATS      Security/channel statistics
#   NETWORKS   Scrollable AP list
#   EXPORT     Export information
#
# Keys:
#   1 / KEY1    Cycle view
#   2 / KEY2    Start / Stop scanning
#   3 / KEY3    Export now
#   4 / KEY4    Exit (hold ~2 sec)
#   ↑ / ↓       Scroll NETWORKS
#   s           Change NETWORKS sort
#   q           Exit
#
set -u
set -o pipefail
VERSION="1.0"
BASE_DIR="${HOME}/wardrive"
DATA_DIR="${BASE_DIR}/data"
EXPORT_DIR="${BASE_DIR}/exports"
AP_DB="${DATA_DIR}/aps.tsv"
GPS_FILE="${DATA_DIR}/gps.tsv"
LOG_FILE="${DATA_DIR}/scanner.log"
mkdir -p "$DATA_DIR" "$EXPORT_DIR"
SCAN_INTERVAL=5
GPS_INTERVAL=1
INTERFACES=()
GPSD_HOST="localhost"
GPSD_PORT="2947"
RUNNING=0
EXITING=0
VIEW=0
NETWORK_OFFSET=0
SORT_MODE=0
declare -a AP_KEYS
declare -A AP_SSID
declare -A AP_BSSID
declare -A AP_CH
declare -A AP_FREQ
declare -A AP_SIGNAL
declare -A AP_SECURITY
declare -A AP_FIRST
declare -A AP_LAST
declare -A AP_COUNT
declare -A AP_IFACE
GPS_LAT=""
GPS_LON=""
GPS_ALT=""
GPS_SPEED=""
GPS_SATS=""
GPS_HDOP=""
GPS_TIME=""
GPS_FIX=0
SCAN_COUNT=0
AP_NEW=0
LAST_EXPORT="Never"
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing dependency: $1"
        exit 1
    }
}
check_dependencies() {
    need_cmd iw
    need_cmd awk
    need_cmd sed
    need_cmd sort
    need_cmd grep
    need_cmd date
    need_cmd stty
    need_cmd tput
    if ! command -v gpspipe >/dev/null 2>&1; then
        echo "Warning: gpspipe not found - GPS disabled."
    fi
}
detect_interfaces() {
    if (( ${#INTERFACES[@]} > 0 )); then
        return
    fi
    INTERFACES=()
    while read -r iface type; do
        [[ "$type" == "wifi" ]] || continue
        [[ -n "$iface" ]] || continue
        INTERFACES+=("$iface")
    done < <(
        iw dev 2>/dev/null |
        awk '
            $1=="Interface" { iface=$2 }
            $1=="type" && $2=="managed" {
                print iface, "wifi"
            }
        '
    )
    if (( ${#INTERFACES[@]} == 0 )); then
        echo "No managed Wi-Fi interfaces detected."
        echo
        iw dev
        exit 1
    fi
}
init_database() {
    if [[ ! -f "$AP_DB" ]]; then
        printf 'BSSID\tSSID\tCHANNEL\tFREQ\tSIGNAL\tSECURITY\tFIRST\tLAST\tCOUNT\tIFACE\n' > "$AP_DB"
    fi
    if [[ ! -f "$GPS_FILE" ]]; then
        printf 'TIME\tLAT\tLON\tALT\tSPEED\tSATS\tHDOP\tFIX\n' > "$GPS_FILE"
    fi
}
load_database() {
    [[ -f "$AP_DB" ]] || return
    while IFS=$'\t' read -r bssid ssid ch freq signal security first last count iface; do
        [[ "$bssid" == "BSSID" ]] && continue
        [[ -n "$bssid" ]] || continue
        AP_KEYS+=("$bssid")
        AP_SSID["$bssid"]="$ssid"
        AP_BSSID["$bssid"]="$bssid"
        AP_CH["$bssid"]="$ch"
        AP_FREQ["$bssid"]="$freq"
        AP_SIGNAL["$bssid"]="$signal"
        AP_SECURITY["$bssid"]="$security"
        AP_FIRST["$bssid"]="$first"
        AP_LAST["$bssid"]="$last"
        AP_COUNT["$bssid"]="$count"
        AP_IFACE["$bssid"]="$iface"
    done < "$AP_DB"
}
get_security() {
    local block="$1"
    local security="OPEN"
    if grep -q "WPA3" <<< "$block"; then security="WPA3"
    elif grep -q "RSN" <<< "$block"; then security="WPA2"
    elif grep -q "WPA" <<< "$block"; then security="WPA"
    elif grep -q "WEP" <<< "$block"; then security="WEP"
    fi
    echo "$security"
}
record_ap() {
    local bssid="$1" ssid="$2" ch="$3" freq="$4" signal="$5" security="$6" iface="$7"
    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    ssid="${ssid//$'\t'/ }"
    ssid="${ssid//$'\n'/ }"
    if [[ -z "${AP_BSSID[$bssid]+x}" ]]; then
        AP_KEYS+=("$bssid")
        AP_SSID["$bssid"]="$ssid"
        AP_BSSID["$bssid"]="$bssid"
        AP_CH["$bssid"]="$ch"
        AP_FREQ["$bssid"]="$freq"
        AP_SIGNAL["$bssid"]="$signal"
        AP_SECURITY["$bssid"]="$security"
        AP_FIRST["$bssid"]="$now"
        AP_LAST["$bssid"]="$now"
        AP_COUNT["$bssid"]=1
        AP_IFACE["$bssid"]="$iface"
        ((AP_NEW++))
    else
        AP_SSID["$bssid"]="$ssid"
        AP_CH["$bssid"]="$ch"
        AP_FREQ["$bssid"]="$freq"
        AP_SIGNAL["$bssid"]="$signal"
        AP_SECURITY["$bssid"]="$security"
        AP_LAST["$bssid"]="$now"
        AP_IFACE["$bssid"]="$iface"
        AP_COUNT["$bssid"]=$(( ${AP_COUNT[$bssid]:-0} + 1 ))
    fi
}
save_database() {
    local tmp="${AP_DB}.tmp"
    printf 'BSSID\tSSID\tCHANNEL\tFREQ\tSIGNAL\tSECURITY\tFIRST\tLAST\tCOUNT\tIFACE\n' > "$tmp"
    for bssid in "${AP_KEYS[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${AP_BSSID[$bssid]}" "${AP_SSID[$bssid]}" "${AP_CH[$bssid]}" \
            "${AP_FREQ[$bssid]}" "${AP_SIGNAL[$bssid]}" "${AP_SECURITY[$bssid]}" \
            "${AP_FIRST[$bssid]}" "${AP_LAST[$bssid]}" "${AP_COUNT[$bssid]}" "${AP_IFACE[$bssid]}"
    done >> "$tmp"
    mv "$tmp" "$AP_DB"
}
scan_interface() {
    local iface="$1"
    local output
    output="$(iw dev "$iface" scan 2>/dev/null)" || return
    local block="" bssid="" ssid="" signal="" freq="" channel="" security="OPEN"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^BSS[[:space:]]+([0-9a-fA-F:]{17}) ]]; then
            if [[ -n "$bssid" ]]; then
                record_ap "$bssid" "$ssid" "$channel" "$freq" "$signal" "$security" "$iface"
            fi
            bssid="${BASH_REMATCH[1]}"
            ssid="" signal="" freq="" channel="" security="OPEN" block=""
            continue
        fi
        block+="$line"$'\n'
        if [[ "$line" =~ SSID:[[:space:]](.*)$ ]]; then ssid="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ signal:[[:space:]](-?[0-9.]+)[[:space:]]dBm ]]; then signal="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ freq:[[:space:]]([0-9]+) ]]; then freq="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ DS\ Parameter\ set:[[:space:]]channel[[:space:]]([0-9]+) ]]; then channel="${BASH_REMATCH[1]}"; fi
    done <<< "$output"
    if [[ -n "$bssid" ]]; then
        security="$(get_security "$block")"
        record_ap "$bssid" "$ssid" "$channel" "$freq" "$signal" "$security" "$iface"
    fi
    ((SCAN_COUNT++))
}
gps_loop() {
    command -v gpspipe >/dev/null 2>&1 || return
    gpspipe -h "$GPSD_HOST" -p "$GPSD_PORT" -w 2>/dev/null |
    while IFS= read -r json; do
        [[ -n "$json" ]] || continue
        local class
        class="$(sed -n 's/.*"class":"\([^"]*\)".*/\1/p' <<< "$json")"
        if [[ "$class" == "TPV" ]]; then
            GPS_LAT="$(sed -n 's/.*"lat":\([-0-9.]*\).*/\1/p' <<< "$json")"
            GPS_LON="$(sed -n 's/.*"lon":\([-0-9.]*\).*/\1/p' <<< "$json")"
            GPS_ALT="$(sed -n 's/.*"alt":\([-0-9.]*\).*/\1/p' <<< "$json")"
            GPS_SPEED="$(sed -n 's/.*"speed":\([-0-9.]*\).*/\1/p' <<< "$json")"
            GPS_TIME="$(sed -n 's/.*"time":"\([^"]*\)".*/\1/p' <<< "$json")"
            if [[ -n "$GPS_LAT" && -n "$GPS_LON" ]]; then GPS_FIX=1; else GPS_FIX=0; fi
        elif [[ "$class" == "SKY" ]]; then
            GPS_SATS="$(grep -o '"PRN"' <<< "$json" | wc -l)"
        fi
        if [[ -n "$GPS_LAT" && -n "$GPS_LON" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$GPS_LAT" "$GPS_LON" \
                "$GPS_ALT" "$GPS_SPEED" "$GPS_SATS" "$GPS_HDOP" "$GPS_FIX" >> "$GPS_FILE"
        fi
    done
}
signal_bars() {
    local sig="${1:-0}" bars=0
    if (( sig >= -50 )); then bars=5
    elif (( sig >= -60 )); then bars=4
    elif (( sig >= -70 )); then bars=3
    elif (( sig >= -80 )); then bars=2
    else bars=1
    fi
    printf '['
    for ((i=0; i<5; i++)); do
        if (( i < bars )); then printf '#'; else printf '.'; fi
    done
    printf ']'
}
security_stats() {
    local open=0 wep=0 wpa=0 wpa2=0 wpa3=0
    for bssid in "${AP_KEYS[@]}"; do
        case "${AP_SECURITY[$bssid]}" in
            OPEN) ((open++)) ;; WEP) ((wep++)) ;; WPA) ((wpa++)) ;;
            WPA2) ((wpa2++)) ;; WPA3) ((wpa3++)) ;;
        esac
    done
    echo "OPEN : $open"
    echo "WEP  : $wep"
    echo "WPA  : $wpa"
    echo "WPA2 : $wpa2"
    echo "WPA3 : $wpa3"
}
channel_stats() {
    declare -A channels
    for bssid in "${AP_KEYS[@]}"; do
        local ch="${AP_CH[$bssid]}"
        [[ -n "$ch" ]] || ch="?"
        ((channels[$ch]++))
    done
    for ch in "${!channels[@]}"; do
        printf "%s\t%s\n" "$ch" "${channels[$ch]}"
    done | sort -n
}
sorted_aps() {
    case "$SORT_MODE" in
        0) for bssid in "${AP_KEYS[@]}"; do printf '%s\t%s\n' "${AP_SIGNAL[$bssid]:--999}" "$bssid"; done | sort -nr | cut -f2 ;;
        1) for bssid in "${AP_KEYS[@]}"; do printf '%s\t%s\n' "${AP_CH[$bssid]:-999}" "$bssid"; done | sort -n | cut -f2 ;;
        2) for bssid in "${AP_KEYS[@]}"; do printf '%s\t%s\n' "${AP_SSID[$bssid]}" "$bssid"; done | sort | cut -f2 ;;
        3) for bssid in "${AP_KEYS[@]}"; do printf '%s\t%s\n' "${AP_BSSID[$bssid]}" "$bssid"; done | sort | cut -f2 ;;
    esac
}
header() {
    clear
    echo "=============================================================="
    echo "                 WARDRIVE SCANNER v$VERSION"
    echo "=============================================================="
    printf "Cards: "
    if (( ${#INTERFACES[@]} )); then printf '%s ' "${INTERFACES[@]}"; fi
    echo
    printf "Status: "
    if (( RUNNING )); then echo "SCANNING"; else echo "STOPPED"; fi
    printf "APs: %-6s  New: %-5s  Scans: %-5s\n" "${#AP_KEYS[@]}" "$AP_NEW" "$SCAN_COUNT"
    echo "--------------------------------------------------------------"
}
view_live() {
    header
    echo "LIVE — recent access points"
    echo
    printf "%-18s %-24s %-5s %-5s %-8s %-6s\n" "BSSID" "SSID" "CH" "SIG" "SEC" "BARS"
    echo "--------------------------------------------------------------"
    local count=0
    while read -r bssid; do
        [[ -n "$bssid" ]] || continue
        local sig="${AP_SIGNAL[$bssid]:-0}"
        printf "%-18s %-24.24s %-5s %-5s %-8s %-6s\n" \
            "$bssid" "${AP_SSID[$bssid]}" "${AP_CH[$bssid]}" "$sig" "${AP_SECURITY[$bssid]}" "$(signal_bars "$sig")"
        ((count++))
        ((count >= 15)) && break
    done < <(sorted_aps)
    echo
    echo "1=View  2=Start/Stop  3=Export  4=Exit"
}
view_gps() {
    header
    echo "GPS"
    echo
    if (( GPS_FIX )); then echo "Fix        : YES"; else echo "Fix        : NO"; fi
    printf "Latitude   : %s\n" "${GPS_LAT:-N/A}"
    printf "Longitude  : %s\n" "${GPS_LON:-N/A}"
    printf "Altitude   : %s m\n" "${GPS_ALT:-N/A}"
    printf "Speed      : %s m/s\n" "${GPS_SPEED:-N/A}"
    printf "Satellites : %s\n" "${GPS_SATS:-N/A}"
    printf "GPS Time   : %s\n" "${GPS_TIME:-N/A}"
    echo
    echo "GPS logging: $GPS_FILE"
    echo
    echo "1=View  2=Start/Stop  3=Export  4=Exit"
}
view_stats() {
    header
    echo "SECURITY DISTRIBUTION"
    echo
    security_stats
    echo
    echo "CHANNEL HEATMAP"
    echo
    channel_stats | while IFS=$'\t' read -r ch count; do
        printf "%4s | " "$ch"
        for ((i=0; i<count; i++)); do printf '#'; done
        printf " (%s)\n" "$count"
    done
    echo
    echo "1=View  2=Start/Stop  3=Export  4=Exit"
}
view_networks() {
    header
    echo "NETWORKS"
    echo
    case "$SORT_MODE" in
        0) echo "Sort: Signal" ;; 1) echo "Sort: Channel" ;;
        2) echo "Sort: SSID" ;; 3) echo "Sort: BSSID" ;;
    esac
    echo
    printf "%-18s %-28s %-5s %-7s %-8s %-6s\n" "BSSID" "SSID" "CH" "SIGNAL" "SEC" "COUNT"
    echo "--------------------------------------------------------------"
    mapfile -t sorted < <(sorted_aps)
    local total="${#sorted[@]}" visible=20
    (( NETWORK_OFFSET < 0 )) && NETWORK_OFFSET=0
    if (( NETWORK_OFFSET >= total )); then NETWORK_OFFSET=$(( total - 1 )); fi
    (( NETWORK_OFFSET < 0 )) && NETWORK_OFFSET=0
    local end=$((NETWORK_OFFSET + visible))
    (( end > total )) && end=$total
    for ((i=NETWORK_OFFSET; i<end; i++)); do
        local bssid="${sorted[$i]}"
        printf "%-18s %-28.28s %-5s %-7s %-8s %-6s\n" \
            "$bssid" "${AP_SSID[$bssid]}" "${AP_CH[$bssid]}" \
            "${AP_SIGNAL[$bssid]}" "${AP_SECURITY[$bssid]}" "${AP_COUNT[$bssid]}"
    done
    echo
    echo "Showing $((NETWORK_OFFSET + 1))-$end of $total"
    echo "↑/↓ Scroll  s=Sort  1=View  3=Export  4=Exit"
}
view_export() {
    header
    echo "EXPORT"
    echo
    echo "Export directory: $EXPORT_DIR"
    echo "Last export: $LAST_EXPORT"
    echo
    find "$EXPORT_DIR" -maxdepth 1 -type f -printf '%f\t%k KB\n' 2>/dev/null | sort | tail -20
    echo
    echo "3=Export now  1=View  2=Start/Stop  4=Exit"
}
render() {
    case "$VIEW" in
        0) view_live ;; 1) view_gps ;; 2) view_stats ;;
        3) view_networks ;; 4) view_export ;;
    esac
}
csv_escape() { local value="$1"; value="${value//\"/\"\"}"; printf '"%s"' "$value"; }
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
export_wigle_csv() {
    local file="$EXPORT_DIR/wardrive-$(date '+%Y%m%d-%H%M%S').csv"
    {
        echo "WigleWifi-1.4,appRelease=WardriveScanner,model=multi-card,release=$VERSION"
        echo "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type,CurrentTimestamp,InternalName,InternalLastUpdate"
        for bssid in "${AP_KEYS[@]}"; do
            local auth=""
            case "${AP_SECURITY[$bssid]}" in
                OPEN) auth="nopass" ;; WEP) auth="WEP" ;; WPA) auth="WPA" ;;
                WPA2) auth="WPA2" ;; WPA3) auth="WPA3" ;; *) auth="${AP_SECURITY[$bssid]}" ;;
            esac
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$bssid" "$(csv_escape "${AP_SSID[$bssid]}")" "$auth" \
                "${AP_FIRST[$bssid]}" "${AP_CH[$bssid]}" "${AP_SIGNAL[$bssid]}" \
                "${GPS_LAT:-0}" "${GPS_LON:-0}" "${GPS_ALT:-0}" "0" "WIFI" \
                "$(date '+%Y-%m-%d %H:%M:%S')" "WardriveScanner" "${AP_LAST[$bssid]}"
        done
    } > "$file"
    LAST_EXPORT="$file"
}
export_json() {
    local file="$EXPORT_DIR/wardrive-$(date '+%Y%m%d-%H%M%S').json"
    {
        echo '{'
        printf '  "generated": "%s",\n' "$(date --iso-8601=seconds)"
        printf '  "gps": {"latitude": %s, "longitude": %s, "altitude": %s, "speed": %s, "satellites": %s},\n' \
            "${GPS_LAT:-null}" "${GPS_LON:-null}" "${GPS_ALT:-null}" "${GPS_SPEED:-null}" "${GPS_SATS:-null}"
        echo '  "networks": ['
        local first=1
        for bssid in "${AP_KEYS[@]}"; do
            (( first )) || echo ','
            first=0
            printf '    {"bssid":"%s","ssid":"%s","channel":"%s","frequency":"%s","signal":"%s","security":"%s","first_seen":"%s","last_seen":"%s","observations":%s}' \
                "$(json_escape "$bssid")" "$(json_escape "${AP_SSID[$bssid]}")" \
                "${AP_CH[$bssid]}" "${AP_FREQ[$bssid]}" "${AP_SIGNAL[$bssid]}" \
                "${AP_SECURITY[$bssid]}" "${AP_FIRST[$bssid]}" "${AP_LAST[$bssid]}" "${AP_COUNT[$bssid]}"
        done
        echo
        echo '  ]'
        echo '}'
    } > "$file"
    LAST_EXPORT="$file"
}
export_kml() {
    local file="$EXPORT_DIR/wardrive-$(date '+%Y%m%d-%H%M%S').kml"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>WardriveScanner</name>'
        for bssid in "${AP_KEYS[@]}"; do
            [[ -n "$GPS_LAT" && -n "$GPS_LON" ]] || continue
            printf '<Placemark><name>%s</name><description>BSSID: %s&lt;br&gt;Channel: %s&lt;br&gt;Signal: %s dBm&lt;br&gt;Security: %s</description><Point><coordinates>%s,%s,%s</coordinates></Point></Placemark>\n' \
                "$(json_escape "${AP_SSID[$bssid]}")" "$bssid" "${AP_CH[$bssid]}" \
                "${AP_SIGNAL[$bssid]}" "${AP_SECURITY[$bssid]}" "$GPS_LON" "$GPS_LAT" "${GPS_ALT:-0}"
        done
        echo '</Document></kml>'
    } > "$file"
    LAST_EXPORT="$file"
}
export_all() {
    save_database
    export_wigle_csv
    export_json
    export_kml
    LAST_EXPORT="$(date '+%Y-%m-%d %H:%M:%S')"
    AP_NEW=0
}
scanner_loop() {
    while (( ! EXITING )); do
        if (( RUNNING )); then
            for iface in "${INTERFACES[@]}"; do
                scan_interface "$iface"
                (( EXITING )) && break
            done
            save_database
        fi
        sleep "$SCAN_INTERVAL"
    done
}
keyboard_loop() {
    local old_stty
    old_stty="$(stty -g)"
    stty -echo -icanon time 0 min 0
    trap 'stty "$old_stty"; exit 0' EXIT
    local key
    while (( ! EXITING )); do
        key="$(dd bs=1 count=1 2>/dev/null)"
        case "$key" in
            1) VIEW=$(( (VIEW + 1) % 5 )); NETWORK_OFFSET=0 ;;
            2) if (( RUNNING )); then RUNNING=0; else RUNNING=1; fi ;;
            3) export_all ;;
            4|q|Q) EXITING=1 ;;
            s|S) if (( VIEW == 3 )); then SORT_MODE=$(( (SORT_MODE + 1) % 4 )); fi ;;
            $'\x1b')
                local seq
                seq="$(dd bs=1 count=2 2>/dev/null)"
                if [[ "$seq" == "[A" ]]; then
                    if (( VIEW == 3 )); then ((NETWORK_OFFSET--)); (( NETWORK_OFFSET < 0 )) && NETWORK_OFFSET=0; fi
                elif [[ "$seq" == "[B" ]]; then
                    if (( VIEW == 3 )); then ((NETWORK_OFFSET++)); fi
                fi
                ;;
        esac
        render
        sleep 0.15
    done
}
cleanup() {
    EXITING=1
    RUNNING=0
    save_database 2>/dev/null || true
    stty sane 2>/dev/null || true
    clear
    echo
    echo "WardriveScanner stopped."
    echo "Data: $DATA_DIR"
    echo "Exports: $EXPORT_DIR"
    echo
}
trap cleanup INT TERM EXIT
check_dependencies
detect_interfaces
init_database
load_database
echo
echo "WardriveScanner v$VERSION"
echo
echo "Interfaces:"
printf '  %s\n' "${INTERFACES[@]}"
echo
echo "Data: $DATA_DIR"
echo "GPS: gpsd://$GPSD_HOST:$GPSD_PORT"
echo
if command -v gpspipe >/dev/null 2>&1; then
    gps_loop &
    GPS_PID=$!
else
    GPS_PID=""
fi
scanner_loop &
SCANNER_PID=$!
render
keyboard_loop
EXITING=1
RUNNING=0
kill "$SCANNER_PID" 2>/dev/null || true
if [[ -n "${GPS_PID:-}" ]]; then kill "$GPS_PID" 2>/dev/null || true; fi
wait "$SCANNER_PID" 2>/dev/null || true
save_database

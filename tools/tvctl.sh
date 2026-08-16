#!/usr/bin/env bash
#
# tvctl.sh — Discover and control smart TVs on the local network.
#
# Discovery methods:
#   - SSDP/UPnP M-SEARCH multicast
#   - mDNS via avahi-browse (Chromecast, AirPlay, etc.)
#   - Targeted nmap port scan for known smart-TV control ports
#
# Control backends (auto-selected by detected brand/port):
#   - Wake-on-LAN (power on, any brand that supports WOL)
#   - Samsung Tizen (encrypted websocket, port 8001/8002) — auth token cached
#     in ~/.tvctl_tokens.json after the first on-TV pairing accept
#   - LG webOS SSAP (websocket, port 3000/3001) — client-key cached the
#     same way, so the on-TV prompt only appears once per TV
#   - Generic UPnP/DLAV AVTransport + RenderingControl (SOAP over HTTP)
#
# Requires (install what's missing):
#   nmap, avahi-utils (avahi-browse), curl, python3
#   python3 -m pip install --break-system-packages websocket-client
#   net-tools or iproute2 (for subnet auto-detect), wakeonlan (optional)
#
set -uo pipefail
# ---------- config / state ----------
WORKDIR="$(mktemp -d /tmp/tvctl.XXXXXX)"
SSDP_TIMEOUT=4
NMAP_TIMEOUT=60
declare -a TV_NAMES TV_IPS TV_TYPES TV_PORTS TV_MACS
STATE_FILE="$HOME/.tvctl_last.json"
TOKEN_FILE="$HOME/.tvctl_tokens.json"
[ -f "$TOKEN_FILE" ] || echo '{}' > "$TOKEN_FILE"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
color() { local c="$1"; shift; case "$c" in
  red) echo -e "\e[31m$*\e[0m" ;; green) echo -e "\e[32m$*\e[0m" ;;
  yellow) echo -e "\e[33m$*\e[0m" ;; blue) echo -e "\e[34m$*\e[0m" ;;
  *) echo "$*" ;; esac ; }
need() { command -v "$1" >/dev/null 2>&1; }
require_tools() {
  local missing=()
  for t in nmap curl python3 awk sed grep; do need "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -gt 0 ]; then
    color yellow "Missing tools: ${missing[*]}"
    color yellow "Install with: sudo apt install -y ${missing[*]}"
  fi
  if ! need avahi-browse; then
    color yellow "avahi-browse not found (mDNS discovery skipped). Install: sudo apt install -y avahi-utils"
  fi
  if ! python3 -c "import websocket" >/dev/null 2>&1; then
    color yellow "python websocket-client not found. Install: python3 -m pip install --break-system-packages websocket-client"
  fi
}
get_subnet() {
  local subnet
  subnet=$(ip -o -f inet addr show 2>/dev/null | awk '!/ lo /{print $4; exit}')
  if [ -z "${subnet:-}" ]; then
    color red "Could not auto-detect subnet. Pass one manually, e.g. 192.168.1.0/24"
    read -rp "Subnet (CIDR): " subnet
  fi
  echo "$subnet"
}
# ---------- discovery: SSDP ----------
discover_ssdp() {
  color blue "[*] SSDP/UPnP discovery (${SSDP_TIMEOUT}s)..."
  python3 - "$SSDP_TIMEOUT" "$WORKDIR/ssdp.txt" <<'PYEOF'
import socket, sys, time
timeout, outfile = float(sys.argv[1]), sys.argv[2]
req = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
       'MAN: "ssdp:discover"\r\nMX: %d\r\nST: ssdp:all\r\n\r\n' % int(timeout)).encode()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.settimeout(timeout)
try:
    s.sendto(req, ('239.255.255.250', 1900))
except OSError as e:
    print("SSDP send failed:", e, file=sys.stderr)
    sys.exit(0)
seen = set()
end = time.time() + timeout
with open(outfile, 'w') as f:
    while time.time() < end:
        try:
            data, addr = s.recvfrom(65535)
        except socket.timeout:
            break
        except OSError:
            break
        ip = addr[0]
        if ip in seen:
            continue
        seen.add(ip)
        f.write("=== %s ===\n" % ip)
        f.write(data.decode(errors='replace'))
        f.write("\n")
PYEOF
  [ -s "$WORKDIR/ssdp.txt" ] || { color yellow "  no SSDP responses"; return; }
  local ip location server
  while read -r ip; do
    location=$(awk -v ip="$ip" '
      $0=="=== "ip" ===" {found=1; next}
      /^=== / {found=0}
      found && tolower($0) ~ /^location:/ {sub(/^[Ll]ocation:[ \t]*/,""); print; exit}
    ' "$WORKDIR/ssdp.txt" | tr -d '\r')
    server=$(awk -v ip="$ip" '
      $0=="=== "ip" ===" {found=1; next}
      /^=== / {found=0}
      found && tolower($0) ~ /^server:/ {sub(/^[Ss]erver:[ \t]*/,""); print; exit}
    ' "$WORKDIR/ssdp.txt" | tr -d '\r')
    local name="Unknown UPnP device"
    if [ -n "$location" ]; then
      local xml
      xml=$(curl -s -m 3 "$location" 2>/dev/null)
      local fn
      fn=$(echo "$xml" | grep -oP '(?<=<friendlyName>)[^<]+' | head -1)
      [ -n "$fn" ] && name="$fn"
    fi
    [ -n "$server" ] && name="$name ($server)"
    add_tv "$name" "$ip" "upnp" ""
  done < <(grep -oP '(?<=^=== )[^ ]+(?= ===)' "$WORKDIR/ssdp.txt" | sort -u)
}
# ---------- discovery: mDNS ----------
discover_mdns() {
  need avahi-browse || return
  color blue "[*] mDNS discovery (Chromecast/AirPlay/DIAL)..."
  local out
  out=$(timeout "$SSDP_TIMEOUT" avahi-browse -a -r -t 2>/dev/null)
  [ -z "$out" ] && { color yellow "  no mDNS responses"; return; }
  echo "$out" | awk '
    /^=/ { svc=$0 }
    /hostname/ { host=$0 }
    /address/ { addr=$0 }
    /^$/ && svc {
      print svc"\n"host"\n"addr"\n---"
      svc=""; host=""; addr=""
    }
  ' > "$WORKDIR/mdns_blocks.txt"
  local name ip
  while IFS= read -r line; do
    if [[ "$line" == \=* ]]; then
      name=$(echo "$line" | sed -E 's/^=[^;]*;[^;]*;[^;]*;([^;]*);.*/\1/')
    elif [[ "$line" =~ address\ =\ \[([0-9.]+)\] ]]; then
      ip="${BASH_REMATCH[1]}"
      [ -n "$name" ] && [ -n "$ip" ] && add_tv "$name (mDNS)" "$ip" "mdns" ""
      name=""; ip=""
    fi
  done < "$WORKDIR/mdns_blocks.txt"
}
# ---------- discovery: targeted port scan ----------
discover_portscan() {
  local subnet="$1"
  color blue "[*] nmap port scan on $subnet for known smart-TV ports (up to ${NMAP_TIMEOUT}s)..."
  timeout "$NMAP_TIMEOUT" nmap -n -Pn --open \
    -p 8001,8002,3000,3001,8008,8009,7676,1925,1926,55000 \
    -oG "$WORKDIR/nmap.gnmap" "$subnet" >/dev/null 2>&1
  [ -s "$WORKDIR/nmap.gnmap" ] || { color yellow "  nmap scan produced no results"; return; }
  grep '/open/' "$WORKDIR/nmap.gnmap" | while read -r line; do
    local ip ports
    ip=$(echo "$line" | awk '{print $2}')
    ports=$(echo "$line" | grep -oP '\d+/open/tcp' | cut -d/ -f1 | tr '\n' ',')
    local type="generic"
    local label="Possible smart TV"
    case ",$ports" in
      *,8001,*|*,8002,*) type="samsung"; label="Samsung Tizen TV" ;;
      *,3000,*|*,3001,*) type="lgwebos"; label="LG webOS TV" ;;
      *,8008,*|*,8009,*) type="chromecast"; label="Chromecast/Google TV" ;;
      *,7676,*|*,1925,*|*,1926,*) type="philips"; label="Philips JointSpace TV" ;;
      *,55000,*) type="sony"; label="Sony Bravia (legacy)" ;;
    esac
    add_tv "$label [ports: $ports]" "$ip" "$type" "$ports"
  done
}
# ---------- helpers ----------
add_tv() {
  local name="$1" ip="$2" type="$3" ports="$4"
  local i
  for i in "${!TV_IPS[@]}"; do
    if [ "${TV_IPS[$i]}" = "$ip" ] && [ "${TV_TYPES[$i]}" = "$type" ]; then return; fi
  done
  local mac
  mac=$(arp -n "$ip" 2>/dev/null | awk '/ether|:/{for(i=1;i<=NF;i++) if ($i ~ /..:..:..:..:..:../) print $i}' | head -1)
  TV_NAMES+=("$name"); TV_IPS+=("$ip"); TV_TYPES+=("$type"); TV_PORTS+=("$ports"); TV_MACS+=("${mac:-}")
}
list_tvs() {
  if [ ${#TV_IPS[@]} -eq 0 ]; then color red "No TVs discovered yet."; return 1; fi
  echo
  printf "%-4s %-40s %-16s %-10s %s\n" "#" "NAME" "IP" "TYPE" "MAC"
  local i
  for i in "${!TV_IPS[@]}"; do
    printf "%-4s %-40s %-16s %-10s %s\n" "$((i+1))" "${TV_NAMES[$i]:0:40}" "${TV_IPS[$i]}" "${TV_TYPES[$i]}" "${TV_MACS[$i]:-unknown}"
  done
  echo
}
run_discovery() {
  TV_NAMES=(); TV_IPS=(); TV_TYPES=(); TV_PORTS=(); TV_MACS=()
  local subnet; subnet=$(get_subnet)
  discover_ssdp
  discover_mdns
  discover_portscan "$subnet"
  list_tvs
}
# ---------- WOL ----------
ctrl_wol() {
  local mac="$1"
  if [ -z "$mac" ]; then
    color red "No MAC address known for this TV; cannot send Wake-on-LAN."
    read -rp "Enter MAC manually (aa:bb:cc:dd:ee:ff) or blank to cancel: " mac
    [ -z "$mac" ] && return
  fi
  if need wakeonlan; then wakeonlan "$mac"
  elif need etherwake; then sudo etherwake "$mac"
  else
    python3 - "$mac" <<'PYEOF'
import socket, sys
mac = sys.argv[1].replace(':', '').replace('-', '')
packet = bytes.fromhex('FF'*6 + mac*16)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(packet, ('255.255.255.255', 9))
print("Magic packet sent to", sys.argv[1])
PYEOF
  fi
}
# ---------- Samsung Tizen ----------
ctrl_samsung() {
  local ip="$1" key="$2"
  python3 - "$ip" "$key" "$TOKEN_FILE" <<'PYEOF'
import sys, json, base64, time, os
try:
    import websocket
except ImportError:
    print("Install with: python3 -m pip install --break-system-packages websocket-client"); sys.exit(1)
ip, key, token_file = sys.argv[1], sys.argv[2], sys.argv[3]
def load_tokens():
    try:
        with open(token_file) as f: return json.load(f)
    except Exception: return {}
def save_tokens(d):
    tmp = token_file + ".tmp"
    with open(tmp, "w") as f: json.dump(d, f, indent=2)
    os.replace(tmp, token_file)
tokens = load_tokens(); entry = tokens.get(ip, {}); token = entry.get("samsung_token", "")
name = base64.b64encode(b"tvctl-script").decode()
url = f"wss://{ip}:8002/api/v2/channels/samsung.remote.control?name={name}"
if token: url += f"&token={token}"
try:
    ws = websocket.create_connection(url, sslopt={"cert_reqs": 0}, timeout=8)
except Exception as e:
    print("Connection failed:", e); print("Accept the pairing prompt on the TV first."); sys.exit(1)
ack_raw = ws.recv()
try: ack = json.loads(ack_raw)
except Exception: ack = {}
if ack.get("event") == "ms.channel.connect":
    new_token = (ack.get("data") or {}).get("token")
    if new_token:
        entry["samsung_token"] = new_token; tokens[ip] = entry; save_tokens(tokens)
        print(f"Paired and cached token for {ip}")
elif ack.get("event") in ("ms.channel.timeOut", "ms.channel.unauthorized"):
    print("Pairing rejected or timed out. Accept the prompt on the TV."); sys.exit(1)
ws.send(json.dumps({"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":key,"Option":"false","TypeOfRemote":"SendRemoteKey"}}))
time.sleep(0.3); ws.close(); print(f"Sent {key} to Samsung TV {ip}")
PYEOF
}
samsung_menu() {
  local ip="$1"
  color blue "Samsung Tizen control — $ip"
  select opt in "Power" "Volume Up" "Volume Down" "Mute" "Home" "Back" "OK" "Up" "Down" "Left" "Right" "Back to main menu"; do
    case "$opt" in
      "Power") ctrl_samsung "$ip" "KEY_POWER" ;;
      "Volume Up") ctrl_samsung "$ip" "KEY_VOLUP" ;;
      "Volume Down") ctrl_samsung "$ip" "KEY_VOLDOWN" ;;
      "Mute") ctrl_samsung "$ip" "KEY_MUTE" ;;
      "Home") ctrl_samsung "$ip" "KEY_HOME" ;;
      "Back") ctrl_samsung "$ip" "KEY_RETURN" ;;
      "OK") ctrl_samsung "$ip" "KEY_ENTER" ;;
      "Up") ctrl_samsung "$ip" "KEY_UP" ;;
      "Down") ctrl_samsung "$ip" "KEY_DOWN" ;;
      "Left") ctrl_samsung "$ip" "KEY_LEFT" ;;
      "Right") ctrl_samsung "$ip" "KEY_RIGHT" ;;
      "Back to main menu"|*) break ;;
    esac
  done
}
# ---------- LG webOS ----------
ctrl_lgwebos() {
  local ip="$1" action="$2"
  python3 - "$ip" "$action" "$TOKEN_FILE" <<'PYEOF'
import sys, json, time, os
try:
    import websocket
except ImportError:
    print("Install with: python3 -m pip install --break-system-packages websocket-client"); sys.exit(1)
ip, action, token_file = sys.argv[1], sys.argv[2], sys.argv[3]
def load_tokens():
    try:
        with open(token_file) as f: return json.load(f)
    except Exception: return {}
def save_tokens(d):
    tmp = token_file + ".tmp"
    with open(tmp, "w") as f: json.dump(d, f, indent=2)
    os.replace(tmp, token_file)
tokens = load_tokens(); entry = tokens.get(ip, {}); client_key = entry.get("lg_client_key")
url = f"ws://{ip}:3000"
register = {"type":"register","id":"register_0","payload":{"forcePairing":False,"pairingType":"PROMPT","manifest":{"manifestVersion":1,"appVersion":"1.1","signed":{"created":"20140509","appId":"com.lge.test","vendorId":"com.lge","localizedAppNames":{"":"tvctl"},"localizedVendorNames":{"":"LGE"},"permissions":["TEST_SECURE","CONTROL_INPUT_TEXT","CONTROL_MOUSE_AND_KEYBOARD","READ_INSTALLED_APPS","CONTROL_POWER","READ_CURRENT_CHANNEL","READ_RUNNING_APPS","READ_UPDATE_INFO","UPDATE_FROM_REMOTE_APP","READ_LGE_TV_INPUT_EVENTS","READ_TV_CURRENT_TIME"],"serial":"2f930e2d2cfe083771f68e4fe7bb07"},"permissions":["LAUNCH","LAUNCH_WEBAPP","APP_TO_APP","CLOSE","TEST_OPEN","TEST_PROTECTED","CONTROL_AUDIO","CONTROL_DISPLAY","CONTROL_INPUT_JOYSTICK","CONTROL_INPUT_MEDIA_RECORDING","CONTROL_INPUT_MEDIA_PLAYBACK","CONTROL_INPUT_TV","CONTROL_POWER","READ_APP_STATUS","READ_CURRENT_CHANNEL","READ_INPUT_DEVICE_LIST","READ_NETWORK_STATE","READ_RUNNING_APPS","READ_TV_CHANNEL_LIST","WRITE_NOTIFICATION_TOAST","READ_POWER_STATE","READ_COUNTRY_INFO"],"signatures":[{"signatureVersion":1,"signature":"eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2In0="}]}}}
if client_key: register["payload"]["client-key"] = client_key
try:
    ws = websocket.create_connection(url, timeout=8)
except Exception as e:
    print("Connection failed:", e); sys.exit(1)
ws.send(json.dumps(register))
resp = None
for _ in range(30 if not client_key else 3):
    try: resp = json.loads(ws.recv())
    except Exception: break
    if resp.get("type") == "registered": break
    time.sleep(1)
if not resp or resp.get("type") != "registered":
    print("Pairing not completed. Accept the prompt on the TV and retry."); sys.exit(1)
new_key = (resp.get("payload") or {}).get("client-key")
if new_key and new_key != client_key:
    entry["lg_client_key"] = new_key; tokens[ip] = entry; save_tokens(tokens)
    print(f"Paired and cached client-key for {ip}")
uris = {"power_off":("ssap://system/turnOff",{}),"vol_up":("ssap://audio/volumeUp",{}),"vol_down":("ssap://audio/volumeDown",{}),"mute":("ssap://audio/setMute",{"mute":True}),"home":("ssap://com.webos.applicationManager/launch",{"id":"com.webos.app.home"})}
uri, payload = uris.get(action,(None,None))
if not uri: print("Unknown action"); sys.exit(1)
ws.send(json.dumps({"type":"request","id":"req_0","uri":uri,"payload":payload}))
time.sleep(0.3); ws.close(); print(f"Sent {action} to LG webOS TV {ip}")
PYEOF
}
lgwebos_menu() {
  local ip="$1"
  color blue "LG webOS control — $ip"
  select opt in "Power Off" "Volume Up" "Volume Down" "Mute" "Home" "Back to main menu"; do
    case "$opt" in
      "Power Off") ctrl_lgwebos "$ip" "power_off" ;;
      "Volume Up") ctrl_lgwebos "$ip" "vol_up" ;;
      "Volume Down") ctrl_lgwebos "$ip" "vol_down" ;;
      "Mute") ctrl_lgwebos "$ip" "mute" ;;
      "Home") ctrl_lgwebos "$ip" "home" ;;
      "Back to main menu"|*) break ;;
    esac
  done
}
# ---------- Generic UPnP ----------
ctrl_upnp_soap() {
  local ip="$1" port="$2" control_url="$3" action="$4" value="$5"
  local soap_action="urn:schemas-upnp-org:service:RenderingControl:1#${action}"
  local body="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:${action} xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><InstanceID>0</InstanceID><Channel>Master</Channel>${value}</u:${action}></s:Body></s:Envelope>"
  curl -s -m 5 -X POST "http://${ip}:${port}${control_url}" \
    -H "Content-Type: text/xml; charset=\"utf-8\"" \
    -H "SOAPAction: \"$soap_action\"" \
    -d "$body" -o /dev/null
  echo "Sent UPnP $action to $ip:$port$control_url"
}
upnp_menu() {
  local ip="$1"
  color yellow "Generic UPnP control — fetch the device XML for the control URL:"
  color yellow "  curl http://$ip:PORT/description.xml"
  read -rp "Enter RenderingControl URL (e.g. /upnp/control/RenderingControl1) or blank to cancel: " curl_path
  [ -z "$curl_path" ] && return
  read -rp "Port [default 49153]: " port; port="${port:-49153}"
  select opt in "Volume Up" "Volume Down" "Mute" "Unmute" "Back to main menu"; do
    case "$opt" in
      "Volume Up") ctrl_upnp_soap "$ip" "$port" "$curl_path" "SetVolume" "<DesiredVolume>60</DesiredVolume>" ;;
      "Volume Down") ctrl_upnp_soap "$ip" "$port" "$curl_path" "SetVolume" "<DesiredVolume>30</DesiredVolume>" ;;
      "Mute") ctrl_upnp_soap "$ip" "$port" "$curl_path" "SetMute" "<DesiredMute>1</DesiredMute>" ;;
      "Unmute") ctrl_upnp_soap "$ip" "$port" "$curl_path" "SetMute" "<DesiredMute>0</DesiredMute>" ;;
      "Back to main menu"|*) break ;;
    esac
  done
}
# ---------- control dispatcher ----------
control_tv() {
  local idx="$1"
  local ip="${TV_IPS[$idx]}" type="${TV_TYPES[$idx]}" mac="${TV_MACS[$idx]}" name="${TV_NAMES[$idx]}"
  color green "Selected: $name ($ip, type=$type)"
  select action in "Power On (WOL)" "Open brand control menu" "Back"; do
    case "$action" in
      "Power On (WOL)") ctrl_wol "$mac" ;;
      "Open brand control menu")
        case "$type" in
          samsung) samsung_menu "$ip" ;;
          lgwebos) lgwebos_menu "$ip" ;;
          *) upnp_menu "$ip" ;;
        esac ;;
      "Back"|*) break ;;
    esac
  done
}
# ---------- main ----------
main_menu() {
  while true; do
    echo
    color blue "=== tvctl — Smart TV Discovery & Control ==="
    select opt in "Discover TVs" "List discovered TVs" "Control a TV" "Quit"; do
      case "$opt" in
        "Discover TVs") run_discovery; break ;;
        "List discovered TVs") list_tvs; break ;;
        "Control a TV")
          list_tvs || break
          read -rp "Enter TV number: " n
          if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#TV_IPS[@]}" ]; then
            control_tv "$((n-1))"
          else
            color red "Invalid selection."
          fi
          break ;;
        "Quit"|*) exit 0 ;;
      esac
    done
  done
}
require_tools
main_menu

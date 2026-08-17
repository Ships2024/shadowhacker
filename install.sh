#!/bin/bash
# Shadow Hacker Installer
# Run as root on Kali Linux

clear
printf '\033]2;Shadow Hacker Installer\a'

YS="\e[1;32m"
CE="\e[0m"
RS="\e[1;31m"
GN="\e[1;32m"
DIM="\e[2m"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RS}Run as root.${CE}"
  exit 1
fi

VERSION=$(cat "$(dirname "${BASH_SOURCE[0]}")/version.txt" 2>/dev/null || echo "1.0.0")

clear
echo -e "${YS}"
echo -e "  ███████╗██╗  ██╗ █████╗ ██████╗  ██████╗ ██╗    ██╗"
echo -e "  ██╔════╝██║  ██║██╔══██╗██╔══██╗██╔═══██╗██║    ██║"
echo -e "  ███████╗███████║███████║██║  ██║██║   ██║██║ █╗ ██║"
echo -e "  ╚════██║██╔══██║██╔══██║██║  ██║██║   ██║██║███╗██║"
echo -e "  ███████║██║  ██║██║  ██║██████╔╝╚██████╔╝╚███╔███╔╝"
echo -e "  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝  ╚══╝╚══╝ ${CE}"
echo -e "  ${DIM}HACKER  v${VERSION}  —  Kali Linux Pentest Framework${CE}"
echo -e "  ────────────────────────────────────────────────────"
echo ""
echo -e "  Press any key to begin installation..."
read -n 1
clear

# ── Progress bar ──────────────────────────────────────────────────────────────
TOTAL_STEPS=33
CURRENT_STEP=0

progress() {
  local label="$1"
  CURRENT_STEP=$(( CURRENT_STEP + 1 ))
  local pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  local filled=$(( CURRENT_STEP * 40 / TOTAL_STEPS ))
  local empty=$(( 40 - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "\r${YS}[${bar}]${CE} %3d%%  %-45s" "$pct" "$label"
}

echo ""
echo -e "${YS}Installing Shadow Hacker...${CE}"
echo ""

# ── Copy to /root/shadowhacker ────────────────────────────────────────────────
progress "Copying files..."
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [[ "$DIR" != "/root/shadowhacker" ]]; then
  rm -rf /root/shadowhacker
  mkdir -p /root/shadowhacker
  cp -r "$DIR"/. /root/shadowhacker/
fi

# ── Set permissions ───────────────────────────────────────────────────────────
progress "Setting permissions..."
chmod +x /root/shadowhacker/bin/shadowhacker
chmod +x /root/shadowhacker/scripts/handshake-helper \
         /root/shadowhacker/scripts/deauth-helper \
         /root/shadowhacker/scripts/monitor-mode \
         /root/shadowhacker/scripts/monitor-setup \
         /root/shadowhacker/scripts/wpa-scan \
         /root/shadowhacker/scripts/wep-capture \
         /root/shadowhacker/scripts/fakeauth \
         /root/shadowhacker/scripts/packet-inject 2>/dev/null
chmod +x /root/shadowhacker/mitm/dns2proxy.sh \
         /root/shadowhacker/mitm/arp-spoof-fwd.sh \
         /root/shadowhacker/mitm/arp-spoof-rev.sh 2>/dev/null
chmod +x /root/shadowhacker/uninstall.sh 2>/dev/null
for f in /root/shadowhacker/tools/*.sh /root/shadowhacker/tools/*.py; do
  [[ -f "$f" ]] && chmod +x "$f"
done

# ── Symlinks ──────────────────────────────────────────────────────────────────
progress "Creating launcher symlinks..."
ln -sf /root/shadowhacker/bin/shadowhacker /usr/local/bin/shadow
ln -sf /root/shadowhacker/scripts/handshake-helper /usr/local/bin/hh
ln -sf /root/shadowhacker/scripts/deauth-helper     /usr/local/bin/dh
ln -sf /root/shadowhacker/scripts/monitor-mode     /usr/local/bin/mm
ln -sf /root/shadowhacker/scripts/wpa-scan         /usr/local/bin/wpa

mkdir -p /root/handshakes /root/wordlists

# ── APT update ────────────────────────────────────────────────────────────────
progress "Updating package lists..."
apt-get update -y -q 2>/dev/null

# ── Core dependencies ─────────────────────────────────────────────────────────
progress "Installing core dependencies..."
apt-get install -y -q \
  git curl wget python3 python3-pip aircrack-ng \
  nmap netdiscover arp-scan macchanger net-tools \
  dnsutils whois iproute2 rfkill wireless-tools \
  gnome-terminal xterm ncurses-dev xdotool wmctrl \
  ettercap-graphical dsniff sslstrip iftop \
  sqlmap wifite metasploit-framework \
  avahi-utils wakeonlan masscan \
  2>/dev/null

# ── MDK3/MDK4 ─────────────────────────────────────────────────────────────────
progress "Installing mdk3/mdk4..."
apt-get install -y -q mdk3 mdk4 2>/dev/null || true

# ── Bluetooth ─────────────────────────────────────────────────────────────────
progress "Installing Bluetooth tools..."
apt-get install -y -q \
  bluez bluez-tools btscanner bluelog spooftooph \
  bluetooth python3-tk rfkill blueranger 2>/dev/null || true
systemctl enable --now bluetooth 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true
pip3 install bleak btlejack --break-system-packages 2>/dev/null || true

# ── Python libs ───────────────────────────────────────────────────────────────
progress "Installing Python libraries..."
pip3 install requests scapy termcolor netifaces websocket-client \
  --break-system-packages 2>/dev/null || true

# ── OpenVAS ───────────────────────────────────────────────────────────────────
progress "Installing OpenVAS/GVM..."
apt-get install -y -q gvm 2>/dev/null || true

# ── Kismet + GPS ──────────────────────────────────────────────────────────────
progress "Installing Kismet + GPS tools..."
apt-get install -y -q kismet gpsd gpsd-clients jq 2>/dev/null || true

# ── Web tools ─────────────────────────────────────────────────────────────────
progress "Installing web pentest tools..."
apt-get install -y -q \
  wfuzz gobuster ffuf nikto hydra hashcat \
  hping3 recon-ng 2>/dev/null || true

# ── Network tools ─────────────────────────────────────────────────────────────
progress "Installing network attack tools..."
apt-get install -y -q \
  bettercap hcxdumptool hcxtools \
  crackmapexec mitm6 responder \
  2>/dev/null || true

# ── RustScan ─────────────────────────────────────────────────────────────────
progress "Installing RustScan..."
if ! command -v rustscan &>/dev/null; then
  RSCAN_URL=$(curl -s https://api.github.com/repos/RustScan/RustScan/releases/latest \
    | grep browser_download_url | grep "amd64.deb" | cut -d '"' -f 4 | head -1)
  if [[ -n "$RSCAN_URL" ]]; then
    wget -q "$RSCAN_URL" -O /tmp/rustscan.deb 2>/dev/null && \
      dpkg -i /tmp/rustscan.deb 2>/dev/null || apt-get install -yf -q 2>/dev/null
    rm -f /tmp/rustscan.deb
  fi
fi

# ── Angry IP Scanner ──────────────────────────────────────────────────────────
progress "Installing Angry IP Scanner..."
if [[ ! -f /usr/bin/ipscan ]]; then
  IPSCAN_VER="3.9.1"
  wget -q "https://github.com/angryip/ipscan/releases/download/${IPSCAN_VER}/ipscan_${IPSCAN_VER}_amd64.deb" \
    -O /tmp/ipscan.deb 2>/dev/null && \
  dpkg -i /tmp/ipscan.deb 2>/dev/null || apt-get install -yf -q 2>/dev/null
  rm -f /tmp/ipscan.deb
fi

# ── Routersploit ──────────────────────────────────────────────────────────────
progress "Installing Routersploit..."
if [[ ! -d /root/routersploit ]]; then
  git clone -q https://github.com/threat9/routersploit.git /root/routersploit 2>/dev/null
  pip3 install -q -r /root/routersploit/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── Netattack2 ────────────────────────────────────────────────────────────────
progress "Installing Netattack2..."
if [[ ! -d /root/netattack2 ]]; then
  git clone -q https://github.com/chrizator/netattack2.git /root/netattack2 2>/dev/null
  [[ -f /root/netattack2/requirements.txt ]] && \
    pip3 install -q -r /root/netattack2/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── TorGhost ──────────────────────────────────────────────────────────────────
progress "Installing TorGhost..."
apt-get install -y -q tor iptables 2>/dev/null || true
if [[ ! -d /root/torghost ]]; then
  git clone -q https://github.com/INTELEON404/torghost.git /root/torghost 2>/dev/null
  [[ -f /root/torghost/requirements.txt ]] && \
    pip3 install -q -r /root/torghost/requirements.txt --break-system-packages 2>/dev/null || true
  chmod +x /root/torghost/torghost.py 2>/dev/null || true
fi

# ── Eternal Scanner ───────────────────────────────────────────────────────────
progress "Installing Eternal Scanner..."
if [[ ! -d /root/eternal_scanner ]]; then
  git clone -q https://github.com/peterpt/eternal_scanner.git /root/eternal_scanner 2>/dev/null
  chmod +x /root/eternal_scanner/escan 2>/dev/null
fi

# ── Villain C2 ────────────────────────────────────────────────────────────────
progress "Installing Villain C2..."
if [[ ! -d /root/Villain ]]; then
  git clone -q https://github.com/t3l3machus/Villain.git /root/Villain 2>/dev/null
  [[ -f /root/Villain/requirements.txt ]] && \
    pip3 install -q -r /root/Villain/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── LFImap ────────────────────────────────────────────────────────────────────
progress "Installing LFImap..."
if [[ ! -d /root/lfimap ]]; then
  git clone -q https://github.com/hansmach1ne/lfimap.git /root/lfimap 2>/dev/null
  [[ -f /root/lfimap/requirements.txt ]] && \
    pip3 install -q -r /root/lfimap/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── Nuclei ────────────────────────────────────────────────────────────────────
progress "Installing Nuclei..."
if ! command -v nuclei &>/dev/null; then
  apt-get install -y -q nuclei 2>/dev/null || \
  (command -v go &>/dev/null && go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest 2>/dev/null) || true
fi

# ── Bettercap caplets ─────────────────────────────────────────────────────────
progress "Installing Bettercap caplets..."
mkdir -p /root/shadowhacker/tools/caplets
[[ -d /root/shadowhacker/tools/caplets ]] && \
  cp -r /root/shadowhacker/tools/caplets/*.cap /usr/share/bettercap/caplets/ 2>/dev/null || true

# ── Sliver C2 ─────────────────────────────────────────────────────────────────
progress "Installing Sliver C2..."
if ! command -v sliver &>/dev/null && [[ ! -f /root/sliver/sliver-server ]]; then
  mkdir -p /root/sliver
  SLIVER_URL=$(curl -s https://api.github.com/repos/BishopFox/sliver/releases/latest \
    | grep browser_download_url | grep "linux_amd64$" | grep sliver-server | cut -d '"' -f 4 | head -1)
  if [[ -n "$SLIVER_URL" ]]; then
    wget -q "$SLIVER_URL" -O /root/sliver/sliver-server 2>/dev/null
    chmod +x /root/sliver/sliver-server 2>/dev/null
    ln -sf /root/sliver/sliver-server /usr/local/bin/sliver 2>/dev/null
  fi
fi

# ── PentestGPT ────────────────────────────────────────────────────────────────
progress "Installing PentestGPT..."
pip3 install -q pentestgpt --break-system-packages 2>/dev/null || true

# ── Haiti (hash identifier) ───────────────────────────────────────────────────
progress "Installing Haiti..."
gem install haiti-hash 2>/dev/null || true


# ── Sparrow-WiFi ──────────────────────────────────────────────────────────────
progress "Installing Sparrow-WiFi..."
if [[ ! -d /root/sparrow-wifi ]]; then
  git clone -q https://github.com/ghostop14/sparrow-wifi.git /root/sparrow-wifi 2>/dev/null
  pip3 install -q -r /root/sparrow-wifi/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── PAYGEN ────────────────────────────────────────────────────────────────────
progress "Installing PAYGEN..."
if [[ ! -d /root/PAYGEN ]]; then
  git clone -q https://github.com/mhaskar/PAYGEN.git /root/PAYGEN 2>/dev/null
  [[ -f /root/PAYGEN/requirements.txt ]] && \
    pip3 install -q -r /root/PAYGEN/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── revshellgen ───────────────────────────────────────────────────────────────
progress "Installing revshellgen..."
if [[ ! -d /root/revshellgen ]]; then
  git clone -q https://github.com/t3l3machus/revshellgen.git /root/revshellgen 2>/dev/null
  [[ -f /root/revshellgen/requirements.txt ]] && \
    pip3 install -q -r /root/revshellgen/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── InternalAllTheThings ──────────────────────────────────────────────────────
progress "Installing InternalAllTheThings..."
if [[ ! -d /root/internalallthethings ]]; then
  git clone -q https://github.com/swisskyrepo/InternalAllTheThings.git /root/internalallthethings 2>/dev/null
fi

# ── HexStrike AI ──────────────────────────────────────────────────────────────
progress "Installing HexStrike AI..."
if [[ ! -d /root/hexstrike-ai ]]; then
  git clone -q https://github.com/0x4m4/hexstrike-ai.git /root/hexstrike-ai 2>/dev/null
  [[ -f /root/hexstrike-ai/requirements.txt ]] && \
    pip3 install -q -r /root/hexstrike-ai/requirements.txt --break-system-packages 2>/dev/null || true
fi


# ── Wifite3 ───────────────────────────────────────────────────────────────────
progress "Installing Wifite3..."
if [[ ! -d /root/wifit3 ]]; then
  git clone -q https://github.com/derv82/wifit3.git /root/wifit3 2>/dev/null
  [[ -f /root/wifit3/requirements.txt ]] && \
    pip3 install -q -r /root/wifit3/requirements.txt --break-system-packages 2>/dev/null || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
progress "Finalising..."
echo ""
echo ""
echo -e "  ${GN}████  Shadow Hacker v${VERSION} installed successfully  ████${CE}"
echo ""
echo -e "  Type ${YS}shadow${CE} in any terminal to launch."
echo -e "  Shortcuts: ${YS}hh${CE} (handshake) ${YS}dh${CE} (deauth) ${YS}mm${CE} (monitor) ${YS}wpa${CE} (scan)"
echo ""
echo -e "  ${YS}Launching Shadow Hacker in 4 seconds...${CE}"
sleep 4
# Open a new gnome-terminal resized to the banner dimensions and launch shadow
gnome-terminal --geometry=90x37 -- bash -c 'shadow; exec bash' 2>/dev/null &
sleep 0.5
# Close this installer terminal
wmctrl -c :ACTIVE: 2>/dev/null || kill $(ps -o ppid= -p $PPID 2>/dev/null) 2>/dev/null || true

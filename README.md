# Shadow Hacker

A terminal-based penetration testing framework for Kali Linux.

## Requirements

- Kali Linux (root)
- `gnome-terminal` or `xterm`

## Install

```bash
git clone https://github.com/Ships2024/shadow-hacker.git
cd shadow-hacker
chmod +x install.sh
sudo ./install.sh
```

Then launch from any terminal:

```bash
shadow
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Structure

```
shadow-hacker/
├── bin/
│   └── shadowhacker            # Main executable
├── scripts/
│   ├── handshake-helper        # WPA handshake capture      (hh)
│   ├── deauth-helper           # Deauth attack helper       (dh)
│   ├── monitor-mode            # Monitor mode toggle        (mm)
│   ├── wpa-scan                # WPA network scan           (wpa)
│   ├── deauth-loop             # Deauth loop subprocess
│   ├── monitor-setup           # Monitor mode setup
│   ├── wep-capture             # WEP IV capture
│   ├── fakeauth                # Fake authentication
│   └── packet-inject           # Packet injection
├── mitm/
│   ├── arp-spoof-fwd.sh        # ARP spoof — forward direction
│   ├── arp-spoof-rev.sh        # ARP spoof — reverse direction
│   └── dns2proxy.sh            # DNS proxy for MITM
├── tools/
│   ├── tvctl.sh                # Smart TV discovery & control
│   ├── wireless_inventory.sh   # Wi-Fi / BT / Zigbee hardware survey
│   ├── hidden_ssid_scanner.sh  # Passive hidden SSID discovery
│   ├── kismet-cli-dashboard.sh # Kismet CLI controller & dashboard
│   ├── wardrivescanner.sh      # Passive wardriving + GPS + WiGLE
│   ├── ble-toy-lab.sh          # BLE Toy Lab launcher
│   └── ble_toy_lab.py          # BLE scanner & GATT inspector (GUI)
├── install.sh
├── uninstall.sh
└── version.txt
```

## Menus

| Menu | Description |
|------|-------------|
| Wi-Fi Tools | Wireless attack & audit frameworks |
| Reconnaissance | Network scanning & discovery tools |
| Remote Access | Payload & RAT tools |
| Information Gathering | OSINT & intel tools |
| Website Tools | Web exploitation tools |
| Bluetooth Tools | BLE/Classic Bluetooth tools |
| Other Tools | Miscellaneous utilities |

## Keyboard shortcuts

| Command | Script               | Description                    |
|---------|----------------------|--------------------------------|
| `shadow`| bin/shadowhacker     | Launch framework               |
| `hh`   | scripts/handshake-helper | WPA handshake capture      |
| `dh`   | scripts/deauth-helper    | Deauth attack helper       |
| `mm`   | scripts/monitor-mode     | Monitor mode toggle        |
| `wpa`   | scripts/wpa-scan         | WPA network scan           |

## Legal

For use only on networks and systems you own or have explicit written authorisation to test.
GPL-3.0 — see LICENSE.

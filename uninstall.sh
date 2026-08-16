#! /bin/bash
YS="\e[1;33m"
CE="\e[0m"
RS="\e[1;31m"

echo -e "${RS}Uninstall Shadow Hacker?${CE} (y/N): "
read -r CHUN
if [[ "$CHUN" != "y" && "$CHUN" != "Y" ]]
then
	echo -e "Cancelled."
	exit
fi

echo -e "Confirm uninstall (y/N): "
read -r CHCHUN
if [[ "$CHCHUN" != "y" && "$CHCHUN" != "Y" ]]
then
	echo -e "Cancelled."
	exit
fi

echo -e "Removing symlinks..."
rm -f /usr/local/bin/shadow
rm -f /usr/local/bin/hh
rm -f /usr/local/bin/dh
rm -f /usr/local/bin/mm
rm -f /usr/local/bin/wpa

echo -e "Removing /root/shadowhacker..."
rm -rf /root/shadowhacker

echo -e "${YS}Shadow Hacker uninstalled.${CE}"

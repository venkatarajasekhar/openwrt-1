#!/bin/sh
append DRIVERS "mac80211"

find_mac80211_phy() {
	config_get device "$1"

	local macaddr="$(config_get "$device" macaddr | tr 'A-Z' 'a-z')"
	config_get phy "$device" phy
	[ -z "$phy" -a -n "$macaddr" ] && {
		for phy in $(ls /sys/class/ieee80211 2>/dev/null); do
			[ "$macaddr" = "$(cat /sys/class/ieee80211/${phy}/macaddress)" ] || continue
			config_set "$device" phy "$phy"
			break
		done
		config_get phy "$device" phy
	}
	[ -n "$phy" -a -d "/sys/class/ieee80211/$phy" ] || {
		echo "PHY for wifi device $1 not found"
		return 1
	}
	[ -z "$macaddr" ] && {
		config_set "$device" macaddr "$(cat /sys/class/ieee80211/${phy}/macaddress)"
	}
	return 0
}

scan_mac80211() {
	local device="$1"
	local adhoc sta ap monitor mesh

	config_get vifs "$device" vifs
	for vif in $vifs; do
		config_get mode "$vif" mode
		case "$mode" in
			adhoc|sta|ap|monitor|mesh)
				append $mode "$vif"
			;;
			*) echo "$device($vif): Invalid mode, ignored."; continue;;
		esac
	done

	config_set "$device" vifs "${ap:+$ap }${adhoc:+$adhoc }${sta:+$sta }${monitor:+$monitor }${mesh:+$mesh}"
}


disable_mac80211() (
	local device="$1"

	find_mac80211_phy "$device" || return 0
	config_get phy "$device" phy

	set_wifi_down "$device"
	# kill all running hostapd and wpa_supplicant processes that
	# are running on atheros/mac80211 vifs
	for pid in `pidof hostapd wpa_supplicant`; do
		grep wlan /proc/$pid/cmdline >/dev/null && \
			kill $pid
	done

	include /lib/network
	for wdev in $(ls /sys/class/ieee80211/${phy}/device/net 2>/dev/null); do
		ifconfig "$wdev" down 2>/dev/null
		unbridge "$dev"
		iw dev "$wdev" del
	done

	return 0
)

enable_mac80211() {
	local device="$1"
	config_get channel "$device" channel
	config_get vifs "$device" vifs
	config_get txpower "$device" txpower
	find_mac80211_phy "$device" || return 0
	config_get phy "$device" phy
	local i=0

	wifi_fixup_hwmode "$device" "g"
	for vif in $vifs; do
		while [ -d "/sys/class/net/wlan$i" ]; do
			i=$(($i + 1))
		done

		config_get ifname "$vif" ifname
		[ -n "$ifname" ] || {
			ifname="wlan$i"
		}
		config_set "$vif" ifname "$ifname"

		config_get enc "$vif" encryption
		config_get mode "$vif" mode
		config_get ssid "$vif" ssid

		# It is far easier to delete and create the desired interface
		case "$mode" in
			adhoc)
				iw phy "$phy" interface add "$ifname" type adhoc
			;;
			ap)
				# Hostapd will handle recreating the interface and
				# it's accompanying monitor
				iw phy "$phy" interface add "$ifname" type managed
			;;
			mesh)
				config_get mesh_id "$vif" mesh_id
				iw phy "$phy" interface add "$ifname" type mp mesh_id "$mesh_id"
			;;
			monitor)
				iw phy "$phy" interface add "$ifname" type monitor
			;;
			sta)
				iw phy "$phy" interface add "$ifname" type managed
			;;
		esac

		# All interfaces must have unique mac addresses
		# which can either be explicitly set in the device 
		# section, or automatically generated
		config_get macaddr "$device" macaddr
		local mac_1="${macaddr%%:*}"
		local mac_2="${macaddr#*:}"

		config_get vif_mac "$vif" macaddr
		[ -n "$vif_mac" ] || {
			if [ "$i" -gt 0 ]; then 
				offset="$(( 2 + $i * 4 ))"
			else
				offset="0"
			fi
			vif_mac="$( printf %02x $(($mac_1 + $offset)) ):$mac_2"
		}
		ifconfig "$ifname" hw ether "$vif_mac"

		# We attempt to set teh channel for all interfaces, although
		# mac80211 may not support it or the driver might not yet
		iw dev "$ifname" set channel "$channel" 

		local key keystring

		# Valid values are:
		# wpa / wep / none
		#
		# !! ap !!
		#
		# ALL ap functionality will be passed to hostapd
		#
		# !! mesh / adhoc / station !!
		# none -> NO encryption
		#
		# wep + keymgmt = '' -> we use iw to connect to the
		# network.  
		#
		# wep + keymgmt = 'NONE' -> wpa_supplicant will be
		# configured to handle the wep connection
		if [ ! "$mode" = "ap" ]; then
			case "$enc" in
				wep)
					config_get keymgmt "$vif" keymgmt
					if [ -e "$keymgmt" ]; then
						for idx in 1 2 3 4; do
							local zidx
							zidx = idx - 1
							config_get key "$vif" "key${idx}"
							if [ -n "$key" ]; then
								append keystring "${zidx}:${key} " 
							fi
						done
					fi
				;;
				wpa)
					config_get key "$vif" key
				;;
			esac
		fi

		# txpower is not yet implemented in iw
		config_get vif_txpower "$vif" txpower
		# use vif_txpower (from wifi-iface) to override txpower (from
		# wifi-device) if the latter doesn't exist
		txpower="${txpower:-$vif_txpower}"
		[ -z "$txpower" ] || iwconfig "$ifname" txpower "${txpower%%.*}"

		config_get frag "$vif" frag
		if [ -n "$frag" ]; then
			iw phy "$phy" set frag "${frag%%.*}"
		fi

		config_get rts "$vif" rts
		if [ -n "$rts" ]; then
			iw phy "$phy" set rts "${frag%%.*}"
		fi

		ifconfig "$ifname" up

		local net_cfg bridge
		net_cfg="$(find_net_config "$vif")"
		[ -z "$net_cfg" ] || {
			bridge="$(bridge_interface "$net_cfg")"
			config_set "$vif" bridge "$bridge"
			start_net "$ifname" "$net_cfg"
		}

		set_wifi_up "$vif" "$ifname"
		case "$mode" in
			ap)
				if eval "type hostapd_setup_vif" 2>/dev/null >/dev/null; then
					hostapd_setup_vif "$vif" nl80211 || {
						echo "enable_mac80211($device): Failed to set up wpa for interface $ifname" >&2
						# make sure this wifi interface won't accidentally stay open without encryption
						ifconfig "$ifname" down
						continue
					}
				fi
			;;
			sta|mesh|adhoc)
				# Fixup... sometimes you have to scan to get beaconing going
				iw dev "$ifname" scan &> /dev/null
				case "$enc" in												 
					wep)
						if [ -e "$keymgmt" ]; then
							[ -n "$keystring" ] &&
								iw dev "$ifname" connect "$ssid" key "$keystring"
						else
							if eval "type wpa_supplicant_setup_vif" 2>/dev/null >/dev/null; then
								wpa_supplicant_setup_vif "$vif" wext || {
									echo "enable_mac80211($device): Failed to set up wpa_supplicant for interface $ifname" >&2
									# make sure this wifi interface won't accidentally stay open without encryption
									ifconfig "$ifname" down
									continue
								}
							fi
						fi
					;;
					wpa)
						if eval "type wpa_supplicant_setup_vif" 2>/dev/null >/dev/null; then
							wpa_supplicant_setup_vif "$vif" wext || {
								echo "enable_mac80211($device): Failed to set up wpa_supplicant for interface $ifname" >&2
								# make sure this wifi interface won't accidentally stay open without encryption
								ifconfig "$ifname" down
								continue
							}
						fi
					;;
				esac

			;;
		esac
	done
}


check_device() {
	config_get phy "$1" phy
	[ -z "$phy" ] && {
		find_mac80211_phy "$1" || return 0
		config_get phy "$1" phy
	}
	[ "$phy" = "$dev" ] && found=1
}

detect_mac80211() {
	devidx=0
	config_load wireless
	for dev in $(ls /sys/class/ieee80211); do
		found=0
		config_foreach check_device wifi-device
		[ "$found" -gt 0 ] && continue

		while :; do 
			config_get type "wifi$devidx" type
			[ -n "$type" ] || break
			devidx=$(($devidx + 1))
		done
		mode_11n=""
		mode_band="g"
		iw phy "$dev" info | grep -q 'HT cap' && mode_11n="n"
		iw phy "$dev" info | grep -q '2412 MHz' || mode_band="a"

		cat <<EOF
config wifi-device  wifi$devidx
	option type     mac80211
	option channel  5
	option macaddr	$(cat /sys/class/ieee80211/${dev}/macaddress)
	option hwmode	11${mode_11n}${mode_band}
	# REMOVE THIS LINE TO ENABLE WIFI:
	option disabled 1

config wifi-iface
	option device   wifi$devidx
	option network  lan
	option mode     ap
	option ssid     OpenWrt
	option encryption none

EOF
	done
}


#!/bin/sh
# ========================================================
# openwrt/usb-gadget.sh - let an OpenWrt router take the
# Pi on its USB port: USB-Ethernet drivers, and usb0 as a
# LAN bridge port. Runs ON the router; from the PC:
#
#   ./deploy.sh router
#
# Re-run it after every flash (a flash drops the drivers).
# Remove it again with:  sh usb-gadget.sh --uninstall
# ========================================================

PKGS="kmod-usb-net-cdc-ether kmod-usb-net-rndis"
PORT=usb0

ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ -f /etc/openwrt_release ] || die "this does not look like OpenWrt"

br=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n1)
[ -n "$br" ] || die "no br-lan device section"

if [ "$1" = --uninstall ]; then
    uci -q del_list "network.$br.ports=$PORT" && uci commit network && service network reload
    ok "$PORT removed from br-lan (drivers left in place)"
    exit 0
fi

missing=""
for P in $PKGS; do apk list --installed 2>/dev/null | grep -q "^$P-[0-9]" || missing="$missing $P"; done
if [ -n "$missing" ]; then
    apk update >/dev/null 2>&1
    apk add $missing >/dev/null 2>&1 || die "couldn't install$missing (no internet?)"
fi
ok "USB-Ethernet drivers installed"

if uci -q get "network.$br.ports" | grep -qw "$PORT"; then
    ok "$PORT already in br-lan"
else
    uci add_list "network.$br.ports=$PORT"
    uci commit network
    service network reload
    ok "$PORT added to br-lan"
fi

if ip link show "$PORT" >/dev/null 2>&1; then
    ok "$PORT present ($(cat "/sys/class/net/$PORT/operstate" 2>/dev/null))"
else
    warn "$PORT not present yet - plug the Pi in (USB port, not PWR)"
fi

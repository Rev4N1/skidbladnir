#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash). On Windows it runs in Git Bash, except
# "sdcard" (see README.md). Settings: skidbladnir.conf.
#
#   ./deploy.sh sdcard            turn on USB gadget mode on a freshly flashed card
#   ./deploy.sh pi [--usb] [step] run setup.sh on the Pi (all|network|system|wifi|
#                                 tailscale|poweroff; default: all)
#   ./deploy.sh router            let an OpenWrt router take the Pi on its USB port
#
#   --usb: the Pi is plugged into this PC (first setup).
# Every target is safe to re-run.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

CONF=skidbladnir.conf
PI_USB_IP=10.12.194.1
KEY="$HOME/.ssh/skidbladnir_ed25519"

# What the Pi gets from skidbladnir.conf. Everything else stays on the PC.
PI_VARS="PI_NAME COUNTRY TS_AUTHKEY PI_MAC HOST_MAC"

say() { printf '\n>>> %s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "${1:-}" in
    sdcard|pi|router) ;;
    *) usage ;;
esac

# ---- config ---------------------------------------------------------

if [ "$1" != sdcard ]; then
    [ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
    set +u; . "./$CONF"; set -u
    : "${PI_HOST:=}" "${PI_PASSWORD:=}" "${TS_AUTHKEY:=}" "${PI_MAC:=}" "${HOST_MAC:=}" "${ROUTER:=}"
    [ -n "$PI_HOST" ] || PI_HOST="${PI_NAME:-}.local"
fi

# require VAR... - each must be set and not CHANGE_ME
require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
    done
}

# sq <value> - single-quoted for any POSIX shell
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# emit VAR... - shell assignments setup.sh can source
emit() {
    local v
    for v in "$@"; do printf '%s=%s\n' "$v" "$(sq "${!v-}")"; done
}

# ---- ssh ------------------------------------------------------------

# deploy.sh logs in with its own key, installed once (with PI_PASSWORD).
# Host keys aren't pinned: every reflash makes new ones.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C skidbladnir-deploy -f "$KEY"
SSH_OPTS=(-i "$KEY" -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# trust <user@host> - install the deploy key unless it already works
trust() {
    ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$1" true 2>/dev/null && return 0
    local add='f=$HOME/.ssh/authorized_keys; umask 077; mkdir -p "${f%/*}"; touch "$f"; k=$(cat);
               grep -qxF "$k" "$f" || echo "$k" >> "$f"; chmod 600 "$f"'
    if [ -n "$PI_PASSWORD" ] && command -v sshpass >/dev/null; then
        SSHPASS=$PI_PASSWORD sshpass -e ssh -o PreferredAuthentications=password,keyboard-interactive \
            "${SSH_OPTS[@]}" "$1" "$add" < "$KEY.pub" || true
    else
        say "authorizing deploy.sh's key on $1 - its password is asked this once"
        [ -n "$PI_PASSWORD" ] && echo "    (install sshpass and it'll use PI_PASSWORD from $CONF instead)"
        ssh "${SSH_OPTS[@]}" "$1" "$add" < "$KEY.pub" || true
    fi
    ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$1" true 2>/dev/null \
        || die "couldn't log in to $1 with the deploy key"
}

# pi_login [--usb] - user@address of the Pi, with the deploy key trusted
pi_login() {
    require PI_USER PI_NAME
    local addr=$PI_HOST
    [ "${1:-}" = --usb ] && addr=$PI_USB_IP
    trust "$PI_USER@$addr" >&2
    echo "$PI_USER@$addr"
}

# Record the MACs "setup.sh network" pinned, so a reflashed Pi gets
# the same ones.
record_macs() {
    local pinned
    pinned=$(ssh "${SSH_OPTS[@]}" "$1" cat /etc/modprobe.d/usb-gadget.conf 2>/dev/null) || return 0
    PI_MAC=$(sed -n 's/.*dev_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    HOST_MAC=$(sed -n 's/.*host_addr=\([^ ]*\).*/\1/p' <<<"$pinned")
    [ -n "$PI_MAC" ] && [ -n "$HOST_MAC" ] || return 0
    sed -i -e "s/^PI_MAC=\"[^\"]*\"/PI_MAC=\"$PI_MAC\"/" \
           -e "s/^HOST_MAC=\"[^\"]*\"/HOST_MAC=\"$HOST_MAC\"/" "$CONF"
    echo "    PI_MAC=$PI_MAC HOST_MAC=$HOST_MAC recorded in $CONF"
}

# ---- targets --------------------------------------------------------

# Add enable_usb_gadget: true under rpi: in the card's cloud-init
# user-data (YAML: one rpi: key, consistent indentation).
cmd_sdcard() {
    command -v findmnt >/dev/null || die "sdcard needs Linux; on Windows edit user-data by hand (README.md)"
    local boot f
    boot=$(findmnt -nro TARGET --source LABEL=bootfs | head -n1)
    [ -n "$boot" ] || die "bootfs isn't mounted - open the SD card in your file manager first"
    f="$boot/user-data"
    [ -f "$f" ] || die "$f not found - flash the card with Raspberry Pi Imager first"
    sed -i 's/\r$//' "$f"
    if ! grep -q 'enable_usb_gadget' "$f"; then
        if grep -q '^rpi:' "$f"; then
            awk '
                add { ind = match($0, /^[ \t]+[^ \t]/) ? substr($0, 1, RLENGTH - 1) : "  "
                      print ind "enable_usb_gadget: true"; add = 0 }
                { print }
                /^rpi:[ \t]*$/ { add = 1 }
                END { if (add) print "  enable_usb_gadget: true" }
            ' "$f" > "$f.new" && mv "$f.new" "$f"
        else
            [ -z "$(tail -c1 "$f")" ] || echo >> "$f"
            printf 'rpi:\n  enable_usb_gadget: true\n' >> "$f"
        fi
    fi
    sync
    grep -A3 '^rpi:' "$f"
    say "USB gadget mode on. Eject the card and boot the Pi from it."
}

# Run setup.sh on the Pi. Script and config travel inside the SSH
# command and are deleted after. With PI_PASSWORD set, sudo is answered
# from it; otherwise sudo asks.
cmd_pi() {
    require PI_NAME COUNTRY
    local where=""
    [ "${1:-}" = --usb ] && { where=--usb; shift; }
    local login s c args unlock=""
    login=$(pi_login $where)
    # shellcheck disable=SC2086
    s=$(base64 -w0 setup.sh); c=$(emit $PI_VARS | base64 -w0)
    [ -n "$PI_PASSWORD" ] && \
        unlock="{ echo $(printf '%s\n' "$PI_PASSWORD" | base64 -w0) | base64 -d | sudo -S -p '' -v 2>/dev/null || true; } &&"
    args=$(printf '%q ' "$@")
    say "setup.sh ${*:-all} on $login"
    ssh -t "${SSH_OPTS[@]}" "$login" "
        d=\$(mktemp -d) && chmod 700 \"\$d\" &&
        echo $s | base64 -d > \"\$d/setup.sh\" && echo $c | base64 -d > \"\$d/pi.conf\" &&
        $unlock sudo bash \"\$d/setup.sh\" $args; rc=\$?; rm -rf \"\$d\"; exit \$rc" || true

    [ "${1:-}" = network ] && record_macs "$login"
    return 0
}

# Run openwrt/usb-gadget.sh on the router (asks its root password).
cmd_router() {
    require ROUTER
    say "OpenWrt router $ROUTER"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$ROUTER" sh -s < openwrt/usb-gadget.sh
}

case "$1" in
    sdcard) cmd_sdcard ;;
    pi)     shift; cmd_pi "$@" ;;
    router) cmd_router ;;
esac

#!/usr/bin/env bash
# ========================================================
# deploy.sh - the one command you run on the PC.
# Linux (bash); README.md also shows every step by hand.
# Settings: skidbladnir.conf.
#
#   ./deploy.sh
#
# No options. It finds the Pi on the USB cable, then over
# Wi-Fi, and runs the whole of setup.sh. That is the same
# command for a freshly flashed Pi and for keeping an
# existing one up to date; every step is safe to re-run.
#
# The SD card is prepared by hand before first boot:
# README.md section 3, step 2.
# ========================================================
set -euo pipefail
cd "$(dirname "$0")"

CONF=skidbladnir.conf
PI_USB_IP=10.12.194.1

# What the Pi gets from skidbladnir.conf. Everything else stays on the PC.
PI_VARS="PI_NAME COUNTRY TS_AUTHKEY"

say()  { printf '\n>>> %s\n' "$*"; }
warn() { printf 'deploy: %s\n' "$*" >&2; }
die()  { printf 'deploy: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "deploy.sh takes no arguments - it always runs the full setup"

# ---- config ---------------------------------------------------------

[ -f "$CONF" ] || die "$CONF is missing: cp -n $CONF.example $CONF, then fill it in"
set +u
# shellcheck source=/dev/null  # the user's file, not in this repo
. "./$CONF"
set -u
: "${PI_USER:=}" "${PI_HOST:=}" "${PI_PASSWORD:=}" "${TS_AUTHKEY:=}"
[ -n "$PI_HOST" ] || PI_HOST="${PI_NAME:-}.local"
[ "$(stat -c %a "$CONF" 2>/dev/null || printf 600)" = 600 ] \
    || warn "chmod 600 $CONF (it holds the Pi's password)"

# require VAR... - each must be set and not CHANGE_ME
require() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE_ME ] || die "set $v in $CONF"
    done
}

# valid_config - the values that end up in hostnames and commands
valid_config() {
    require PI_USER PI_NAME COUNTRY
    case "$COUNTRY" in
        [A-Z][A-Z]) ;;
        *) die "COUNTRY must be a two-letter ISO code (e.g. DE)" ;;
    esac
    case "$PI_NAME" in
        ""|-*|*-|*[!a-z0-9-]*) die "PI_NAME must be a hostname: a-z, 0-9 and -" ;;
    esac
    case "$PI_USER" in
        ""|-*|*[!a-z0-9_-]*) die "PI_USER must be a lowercase username" ;;
    esac
}

# sq <value> - single-quoted for any POSIX shell
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# b64 - base64 without newlines (GNU and BSD)
b64() { base64 | tr -d '\n'; }

# emit VAR... - shell assignments setup.sh can source
emit() {
    local v
    for v in "$@"; do printf '%s=%s\n' "$v" "$(sq "${!v-}")"; done
}

# ---- ssh ------------------------------------------------------------

# Passwords only. With sshpass installed, PI_PASSWORD is typed for you;
# without it, ssh asks. Host keys aren't pinned: every reflash makes
# new ones.
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR)

# pw <ssh|scp> <args...> - run it, typing PI_PASSWORD when sshpass is there
pw() {
    if [ -n "$PI_PASSWORD" ] && command -v sshpass >/dev/null; then
        SSHPASS=$PI_PASSWORD sshpass -e "$@"
    else
        "$@"
    fi
}

# have_ssh <address> - is SSH reachable there? The firewall closes port 22
# on Wi-Fi once deployed, so this also tells us which route works now.
have_ssh() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null
    else
        (exec 3<>"/dev/tcp/$1/22") 2>/dev/null
    fi
}

# pi_pick - user@address of the first Pi that answers: the USB cable
# first (it's there whenever you're setting the Pi up), then its
# Tailscale name (MagicDNS, from any device on your tailnet: the way in
# once the firewall closes SSH on Wi-Fi), then Wi-Fi (<PI_NAME>.local,
# or PI_HOST; only before the firewall is on).
pi_pick() {
    local c cands=("$PI_USB_IP" "$PI_NAME" "$PI_HOST")
    for c in "${cands[@]}"; do
        [ -n "$c" ] || continue
        if have_ssh "$c"; then printf '%s' "$PI_USER@$c"; return 0; fi
        printf '  %s: no SSH\n' "$c" >&2
    done
    return 1
}

pi_login() {
    local login
    login=$(pi_pick) \
        || die "can't reach the Pi: plug in the USB cable, or join your tailnet (Wi-Fi only works before the firewall is on)"
    printf '%s' "$login"
}

# ---- deploy ---------------------------------------------------------

# setup.sh travels inside the SSH command with pi.conf and is deleted
# afterwards (also on a signal, via the remote trap). With PI_PASSWORD
# set, sudo is answered from it; otherwise sudo asks.
cmd_deploy() {
    valid_config
    local login s c unlock="" rc=0
    login=$(pi_login)
    s=$(b64 < setup.sh)
    c=$(emit $PI_VARS | b64)
    [ -n "$PI_PASSWORD" ] && \
        unlock="{ echo $(printf '%s\n' "$PI_PASSWORD" | b64) | base64 -d | sudo -S -p '' -v 2>/dev/null || true; } &&"
    say "full setup on $login"
    pw ssh -t "${SSH_OPTS[@]}" "$login" "
        d=\$(mktemp -d) && chmod 700 \"\$d\" && trap 'rm -rf \"\$d\"' EXIT HUP INT TERM &&
        echo $s | base64 -d > \"\$d/setup.sh\" && echo $c | base64 -d > \"\$d/pi.conf\" &&
        $unlock sudo bash \"\$d/setup.sh\"" || rc=$?
    # setup.sh schedules its reboot detached and returns 0, so 255 is SSH
    # itself failing (wrong PI_PASSWORD, or the link dropped mid-run).
    case "$rc" in
        0)   ;;
        255) die "SSH to $login failed (wrong PI_PASSWORD, or the connection dropped) - re-run" ;;
        *)   die "setup failed on the Pi (exit $rc)" ;;
    esac
}

cmd_deploy

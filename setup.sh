#!/bin/bash
# ========================================================
# setup.sh - Raspberry Pi Zero 2 W as a portable
# Tailscale exit node and subnet router for whatever Wi-Fi
# it's on. Runs as root on the Pi; deploy.sh copies it
# over with pi.conf (written from skidbladnir.conf), runs
# it, and deletes both.
#
#   setup.sh                              everything
#   setup.sh system|wifi|usb|tailscale|firewall   one step
#
# Every step converges: re-running it changes only what
# differs, and keeps the Tailscale login.
# ========================================================
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ -r "$DIR/pi.conf" ] || die "pi.conf not found next to $0 - run this through ./deploy.sh"
# Without CRs, in case the config was last saved on Windows.
# shellcheck source=/dev/null  # written by deploy.sh next to this script
. <(tr -d '\r' < "$DIR/pi.conf")

NEED_REBOOT=0
CFG=/boot/firmware/config.txt
[ -f "$CFG" ] || die "$CFG not found - this needs Raspberry Pi OS Lite (Trixie)"

# write_if_changed <path> - stdin is the wanted content. Leaves the file
# untouched when it already matches, so nothing needless is rewritten.
write_if_changed() {
    local want
    want=$(cat)
    [ "$(cat "$1" 2>/dev/null)" = "$want" ] && return 0
    printf '%s\n' "$want" > "$1"
}

# ---- system: update, then strip it down ---------------------------
phase_system() {
    hdr "Packages"
    export DEBIAN_FRONTEND=noninteractive
    # A first run may have no internet yet (no Wi-Fi configured, or out of
    # range). Don't die here: Wi-Fi and USB still need configuring, and the
    # next run updates once it is online.
    if apt-get -qq -o Acquire::Retries=3 update; then
        apt-get -qq -o Acquire::Retries=3 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold full-upgrade \
            || warn "package upgrade failed - re-run once online"
        apt-get -qq -o Acquire::Retries=3 install unattended-upgrades \
            || warn "couldn't install unattended-upgrades - re-run once online"
        apt-get -qq autoremove || true
    else
        warn "no internet - package updates skipped; re-run once online"
    fi
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
    # Security and Debian's stable updates, plus the Raspberry Pi archive,
    # where the kernel and firmware come from. Security is listed here
    # explicitly, not left to the package's default. A reboot an update
    # needs happens at 04:30. Old kernels and dependencies are removed, or
    # a card in use for years fills up.
    cat > /etc/apt/apt.conf.d/52skidbladnir <<'EOF'
// Written by skidbladnir's setup.sh.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates";
        "origin=Raspberry Pi Foundation,codename=${distro_codename}";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    [ -e /run/reboot-required ] && NEED_REBOOT=1
    ok "up to date; updates install themselves, rebooting at 04:30 if needed"

    hdr "Watchdog"
    # The SoC's hardware watchdog: if the system hangs for 14 s, it
    # reboots by itself instead of staying dead until someone pulls power.
    mkdir -p /etc/systemd/system.conf.d
    want=$(printf '[Manager]\nRuntimeWatchdogSec=14s\nRebootWatchdogSec=2min')
    if [ "$(cat /etc/systemd/system.conf.d/watchdog.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/systemd/system.conf.d/watchdog.conf
        systemctl daemon-reexec
    fi
    ok "a hang reboots it within 14 s"

    hdr "SD card"
    # Logs in RAM only (lost on reboot). Trixie has no rsyslog, so this
    # covers all logging.
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n' > /etc/systemd/journald.conf.d/volatile.conf
    systemctl restart systemd-journald
    # Swap is already compressed RAM only (zram), and / already noatime.
    systemctl disable --now man-db.timer >/dev/null 2>&1 || true
    ok "logs in RAM, no daily man-db rebuild"

    hdr "Unused hardware"
    systemctl disable --now bluetooth.service >/dev/null 2>&1 || true
    systemctl disable --now getty@tty1.service serial-getty@ttyAMA0.service >/dev/null 2>&1 || true
    before=$(md5sum < "$CFG")
    # No display, camera or audio: drop the KMS driver, give the GPU the
    # minimum RAM. Bluetooth and the activity LED off; Wi-Fi stays on.
    sed -i -e 's/^dtoverlay=vc4-kms-v3d/#&/' \
           -e 's/^dtparam=audio=on$/dtparam=audio=off/' \
           -e 's/^camera_auto_detect=1$/camera_auto_detect=0/' \
           -e 's/^display_auto_detect=1$/display_auto_detect=0/' "$CFG"
    [ -z "$(tail -c1 "$CFG")" ] || echo >> "$CFG"
    [ "$(awk '/^\[/ {s=$0} END {print s}' "$CFG")" = "[all]" ] || echo "[all]" >> "$CFG"
    # gpu_mem=16 boots the cut-down firmware (start_cd.elf).
    for l in dtoverlay=disable-bt gpu_mem=16 \
             dtparam=act_led_trigger=none dtparam=act_led_activelow=on; do
        grep -qxF "$l" "$CFG" || echo "$l" >> "$CFG"
    done
    [ "$(md5sum < "$CFG")" = "$before" ] || NEED_REBOOT=1
    ok "Bluetooth, LED, display, audio, consoles off"
}

# ---- wifi: the Pi's only uplink ------------------------------------
# It joins any Wi-Fi saved with nmcli.
phase_wifi() {
    hdr "Wi-Fi"
    # Wi-Fi and its country come from Raspberry Pi Imager. Power saving
    # makes brcmfmac add up to ~100 ms of latency. And a Wi-Fi that
    # drops is retried forever, not just 4 times.
    mkdir -p /etc/NetworkManager/conf.d
    want=$(printf '[connection]\nwifi.powersave = 2\nconnection.autoconnect-retries = 0')
    if [ "$(cat /etc/NetworkManager/conf.d/skidbladnir.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/NetworkManager/conf.d/skidbladnir.conf
        nmcli general reload conf >/dev/null 2>&1 || true
    fi
    ok "on, power saving off, reconnects forever"
}

# ---- usb: a cable to your laptop, never a network uplink -----------
# With USB gadget mode on (README.md section 3, step 2), rpi-usb-gadget's switcher
# (rpi-usb-gadget-ics, which must stay ENABLED: it's what brings usb0
# up) serves the laptop an address and is itself at 10.12.194.1. This
# only stops it offering itself as the laptop's gateway and DNS, so the
# laptop keeps its own internet and just gets a link to the Pi.
phase_usb() {
    hdr "USB link to a laptop"
    if ! nmcli -t -f NAME connection show | grep -qx 'USB Gadget (shared)'; then
        warn "USB gadget mode is off (README.md section 3, step 2) - skipped"
        return
    fi
    # Enable only: it already ran at boot, and starting it again could
    # re-switch usb0 under a deploy that is running over that cable.
    systemctl enable rpi-usb-gadget-ics.service >/dev/null 2>&1 \
        || die "can't enable rpi-usb-gadget-ics.service - it's what brings usb0 up"
    mkdir -p /etc/NetworkManager/dnsmasq-shared.d
    # 99- runs after rpi-usb-gadget's 90-...-lease.conf, so these empty
    # options win: the laptop gets no default route or DNS from the Pi.
    want=$(printf 'dhcp-option=option:router\ndhcp-option=option:dns-server')
    if [ "$(cat /etc/NetworkManager/dnsmasq-shared.d/99-skidbladnir.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/NetworkManager/dnsmasq-shared.d/99-skidbladnir.conf
        NEED_REBOOT=1
    fi
    ok "laptop gets an address, the Pi is at 10.12.194.1, no gateway or DNS offered"
}

# ---- firewall: the host's own SSH, off untrusted Wi-Fi -------------
# Tailscale's rules handle forwarding; this only keeps the Pi's sshd off
# networks you don't control. The laptop cable and the tailnet still
# reach it. Established connections are kept, so the deploy that installs
# this does not cut its own session.
phase_firewall() {
    hdr "Firewall"
    # nftables ships with Raspberry Pi OS Lite, disabled.
    command -v nft >/dev/null || die "nft not found - this needs Raspberry Pi OS Lite (Trixie)"
    # The first table/delete pair makes this file safe to load again, at
    # boot and below. No `flush ruleset`, so tailscaled's own tables are
    # never touched.
    write_if_changed /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Written by skidbladnir's setup.sh.
table inet skidbladnir
delete table inet skidbladnir
table inet skidbladnir {
    chain input {
        type filter hook input priority 0; policy accept;
        ct state established,related accept
        iifname { "lo", "usb0", "tailscale0" } accept
        tcp dport 22 drop
    }
}
EOF
    # Debian's nftables.service stops with `nft flush ruleset`, which would
    # also wipe Tailscale's tables (exit node and routes dead until a
    # reboot) whenever it's stopped or restarted, an nftables upgrade
    # included. Stopping it now only removes this table.
    mkdir -p /etc/systemd/system/nftables.service.d
    write_if_changed /etc/systemd/system/nftables.service.d/skidbladnir.conf <<'EOF'
# Written by skidbladnir's setup.sh: never flush Tailscale's tables.
[Service]
ExecStop=
ExecStop=-/usr/sbin/nft delete table inet skidbladnir
EOF
    systemctl daemon-reload
    systemctl enable nftables.service >/dev/null 2>&1 \
        || warn "couldn't enable nftables at boot - re-run this step"
    # Load the file directly: it only replaces its own table.
    nft -f /etc/nftables.conf || die "couldn't load /etc/nftables.conf"
    ok "SSH on the USB cable and Tailscale only; nothing else is filtered"
}

# ---- tailscale: exit node + whatever Wi-Fi the Pi is on ------------
# Tailscale needs no port forward and works behind any NAT, so the Pi
# works from wherever it is. A NetworkManager hook advertises the Wi-Fi
# network it's on right now, so Tailscale clients reach that whole LAN.
phase_tailscale() {
    hdr "Tailscale"
    if ! command -v tailscale >/dev/null; then
        . /etc/os-release
        curl -fsSL --retry 5 --retry-delay 2 \
            "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL --retry 5 --retry-delay 2 \
            "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get -qq -o Acquire::Retries=3 update
        DEBIAN_FRONTEND=noninteractive apt-get -qq -o Acquire::Retries=3 install tailscale
    fi
    # No support logging: it buffers logs on the SD card. Append to any
    # flags already there instead of replacing them.
    if ! grep -q -- '--no-logs-no-support' /etc/default/tailscaled 2>/dev/null; then
        if grep -q '^FLAGS=' /etc/default/tailscaled 2>/dev/null; then
            sed -i 's/^FLAGS="\(.*\)"$/FLAGS="\1 --no-logs-no-support"/' /etc/default/tailscaled
        else
            echo 'FLAGS="--no-logs-no-support"' >> /etc/default/tailscaled
        fi
        systemctl restart tailscaled
    fi
    systemctl enable tailscaled >/dev/null 2>&1 || true
    systemctl start tailscaled || die "tailscaled didn't start (journalctl -u tailscaled)"
    # A Zero 2 W takes a moment to create the socket; asking before it
    # exists looks like "logged out" and starts a second, failing login.
    i=0
    while [ "$i" -lt 20 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
        i=$((i + 1)); sleep 1
    done

    # Exit node and subnet router both need forwarding. Forwarding also
    # makes the kernel ignore IPv6 router advertisements, so ask for them
    # explicitly or the Pi loses its own IPv6 uplink.
    cat > /etc/sysctl.d/99-skidbladnir.conf <<'EOF'
# Written by skidbladnir's setup.sh.
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
EOF
    sysctl -q --system 2>/dev/null || true
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || die "couldn't enable IPv4 forwarding"
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ] || die "couldn't enable IPv6 forwarding"

    flags="--hostname=$PI_NAME --advertise-exit-node --accept-dns=false"
    if tailscale status >/dev/null 2>&1; then
        # Logged in: "set" changes just these, without touching the login.
        # shellcheck disable=SC2086
        tailscale set $flags || die "tailscale set failed"
    else
        # First login: with TS_AUTHKEY, or it prints a link to open.
        # shellcheck disable=SC2086
        tailscale up $flags ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"} || die "tailscale up failed"
    fi
    tailscale set --auto-update=true >/dev/null 2>&1 || warn "couldn't turn on Tailscale auto-updates"

    # Advertise the Wi-Fi network the Pi is on, now and on every change.
    # The work lives in a oneshot unit: the NetworkManager hook then never
    # blocks NM, and at boot the unit can wait for tailscaled and Wi-Fi.
    cat > /usr/local/sbin/skidbladnir-routes <<'EOF'
#!/bin/sh
# Written by skidbladnir's setup.sh. Advertises the IPv4 network wlan0 is
# on as a Tailscale subnet route.
i=0
while [ "$i" -lt 30 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
    i=$((i + 1)); sleep 1
done
routes=""
i=0
while [ "$i" -lt 60 ]; do
    routes=$(ip -4 route show proto kernel scope link dev wlan0 2>/dev/null |
             awk '{print $1}' | paste -sd, -)
    [ -n "$routes" ] && break
    i=$((i + 1)); sleep 1
done
# No route (Wi-Fi down): keep the last advertisement instead of clearing it.
[ -n "$routes" ] || exit 0
# The exit-node flag again, or "set" would drop it along with the old routes.
tailscale set --advertise-exit-node --advertise-routes="$routes"
EOF
    chmod 755 /usr/local/sbin/skidbladnir-routes

    cat > /etc/systemd/system/skidbladnir-routes.service <<'EOF'
[Unit]
Description=Advertise the Wi-Fi LAN as a Tailscale subnet route
Wants=tailscaled.service
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/skidbladnir-routes

[Install]
WantedBy=multi-user.target
EOF

    hook=/etc/NetworkManager/dispatcher.d/90-tailscale-routes
    cat > "$hook" <<'EOF'
#!/bin/sh
# Written by skidbladnir's setup.sh. Runs the route advertiser on every
# network change, without blocking NetworkManager.
case "$2" in
    up|down|dhcp4-change) systemctl start --no-block skidbladnir-routes.service ;;
esac
EOF
    chmod 755 "$hook"
    systemctl daemon-reload
    systemctl enable skidbladnir-routes.service >/dev/null 2>&1 \
        || warn "couldn't enable skidbladnir-routes at boot"
    systemctl start --no-block skidbladnir-routes.service
    ok "$(tailscale ip -4 2>/dev/null | head -n1) as $PI_NAME: exit node + $(ip -4 route show proto kernel scope link dev wlan0 2>/dev/null | awk '{printf "%s ", $1}')"
}

# ---- main ----------------------------------------------------------
case "${1:-all}" in
    system)    phase_system ;;
    wifi)      phase_wifi ;;
    usb)       phase_usb ;;
    firewall)  phase_firewall ;;
    tailscale) phase_tailscale ;;
    all)
        phase_system
        phase_wifi
        phase_usb
        # Only close SSH on Wi-Fi once Tailscale is actually up: an offline
        # first run must not lock you out of the one path that still works.
        if ( phase_tailscale ); then
            phase_firewall
        else
            warn "Tailscale not set up - Wi-Fi SSH left open; re-run once online"
        fi
        ;;
    *) die "usage: setup.sh [system|wifi|usb|tailscale|firewall|all]" ;;
esac

if [ "$NEED_REBOOT" = 1 ]; then
    hdr "Done - rebooting in 5 s to apply changes"
    # Detached, so this SSH command can return 0 and clean up its temp
    # dir before the reboot ends the session.
    systemd-run --quiet --collect --on-active=5 --unit=skidbladnir-reboot systemctl reboot
else
    hdr "Done"
fi

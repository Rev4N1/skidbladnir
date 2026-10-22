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
#   setup.sh poweroff                     shut down
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
CMD=/boot/firmware/cmdline.txt
[ -f "$CFG" ] || die "$CFG not found - this needs Raspberry Pi OS Lite (Trixie)"
[ -f "$CMD" ] || die "$CMD not found - this needs Raspberry Pi OS Lite (Trixie)"

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
    apt-get -qq -o Acquire::Retries=3 update
    apt-get -qq -o Acquire::Retries=3 -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold full-upgrade
    apt-get -qq -o Acquire::Retries=3 install unattended-upgrades curl
    apt-get -qq autoremove
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
    # Beyond Debian's security updates (the default): Debian's stable
    # updates and the Raspberry Pi archive, where the kernel and firmware
    # come from. A reboot an update needs happens at 04:30. Old kernels
    # and dependencies are removed, or a card in use for years fills up.
    cat > /etc/apt/apt.conf.d/52skidbladnir <<'EOF'
// Written by skidbladnir's setup.sh.
Unattended-Upgrade::Origins-Pattern {
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
    # Swap in compressed RAM only (the default also writes to /var/swap).
    mkdir -p /etc/rpi/swap.conf.d
    if [ "$(cat /etc/rpi/swap.conf.d/50-zram-only.conf 2>/dev/null)" != "$(printf '[Main]\nMechanism=zram')" ]; then
        printf '[Main]\nMechanism=zram\n' > /etc/rpi/swap.conf.d/50-zram-only.conf
        NEED_REBOOT=1
    fi
    systemctl disable --now man-db.timer >/dev/null 2>&1 || true
    findmnt -no OPTIONS / | grep -q noatime || warn "/ is not mounted noatime"
    ok "logs and swap in RAM, no daily man-db rebuild"

    # One line per boot and per clean shutdown. A crash or a power cut
    # shows up as a boot with no "clean shutdown" before it. Capped at
    # 60 lines, so this is a few KB even after years.
    hdr "Boot record"
    cat > /usr/local/sbin/skidbladnir-note <<'EOF'
#!/bin/sh
# Written by skidbladnir's setup.sh.
f=/var/log/skidbladnir.log
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$f"
tail -n 60 "$f" > "$f.new" && mv "$f.new" "$f"
EOF
    chmod 755 /usr/local/sbin/skidbladnir-note
    cat > /etc/systemd/system/skidbladnir-note.service <<'EOF'
[Unit]
Description=skidbladnir boot record

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/skidbladnir-note boot
ExecStop=/usr/local/sbin/skidbladnir-note "clean shutdown"

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now skidbladnir-note.service >/dev/null 2>&1 || true
    ok "boots and clean shutdowns recorded in /var/log/skidbladnir.log"

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
    for l in dtoverlay=disable-bt \
             dtparam=act_led_trigger=none dtparam=act_led_activelow=on; do
        grep -qxF "$l" "$CFG" || echo "$l" >> "$CFG"
    done
    # gpu_mem=16 makes the firmware boot start_cd.elf: only if it's there.
    if [ -f /boot/firmware/start_cd.elf ]; then
        grep -qxF gpu_mem=16 "$CFG" || echo gpu_mem=16 >> "$CFG"
    fi
    [ "$(md5sum < "$CFG")" = "$before" ] || NEED_REBOOT=1
    ok "Bluetooth, LED, display, audio, consoles off"
}

# ---- wifi: the Pi's only uplink ------------------------------------
# It joins any Wi-Fi saved with nmcli.
phase_wifi() {
    hdr "Wi-Fi"
    # Country on the kernel command line: it applies at boot, before
    # wlan0 exists (on the first run it only appears after the reboot).
    if ! grep -qw "cfg80211.ieee80211_regdom=$COUNTRY" "$CMD"; then
        sed -i -e 's/ *cfg80211\.ieee80211_regdom=[^ ]*//' -e "1s/\$/ cfg80211.ieee80211_regdom=$COUNTRY/" "$CMD"
        NEED_REBOOT=1
    fi
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on
    # Power saving makes brcmfmac add up to ~100 ms of latency. And a
    # Wi-Fi that drops is retried forever, not just 4 times.
    mkdir -p /etc/NetworkManager/conf.d
    want=$(printf '[connection]\nwifi.powersave = 2\nconnection.autoconnect-retries = 0')
    if [ "$(cat /etc/NetworkManager/conf.d/skidbladnir.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/NetworkManager/conf.d/skidbladnir.conf
        nmcli general reload conf >/dev/null 2>&1 || true
    fi
    ok "on, country $COUNTRY, power saving off, reconnects forever"
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
    systemctl enable rpi-usb-gadget-ics.service >/dev/null 2>&1 \
        || die "can't enable rpi-usb-gadget-ics.service - it's what brings usb0 up"
    mkdir -p /etc/NetworkManager/dnsmasq-shared.d
    want=$(printf 'dhcp-option=option:router\ndhcp-option=option:dns-server')
    if [ "$(cat /etc/NetworkManager/dnsmasq-shared.d/skidbladnir.conf 2>/dev/null)" != "$want" ]; then
        printf '%s\n' "$want" > /etc/NetworkManager/dnsmasq-shared.d/skidbladnir.conf
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
    if ! command -v nft >/dev/null; then
        apt-get -qq -o Acquire::Retries=3 update
        apt-get -qq -o Acquire::Retries=3 install nftables
    fi
    command -v nft >/dev/null || die "couldn't install nftables (no internet?) - re-run once online"
    # The first table/delete pair makes this file safe to load again:
    # /etc/nftables.conf is read at boot and by the restart below. No
    # `flush ruleset`, so tailscaled's own tables are never touched.
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
    systemctl enable nftables.service >/dev/null 2>&1 \
        || warn "couldn't enable nftables at boot - re-run this step"
    systemctl restart nftables.service
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
    # explicitly or the Pi loses its own IPv6 uplink. fq/BBR and larger
    # socket buffers are for userspace WireGuard on a 1 GHz core.
    cat > /etc/sysctl.d/99-skidbladnir.conf <<'EOF'
# Written by skidbladnir's setup.sh.
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=4194304
net.core.wmem_max=4194304
EOF
    rm -f /etc/sysctl.d/99-tailscale.conf
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
    poweroff)
        hdr "Shutting down - wait for the activity to stop, then unplug"
        systemd-run --quiet --collect --on-active=3 --unit=skidbladnir-poweroff \
            systemctl poweroff 2>/dev/null || systemctl poweroff
        exit 0
        ;;
    all)
        phase_system
        phase_wifi
        phase_usb
        phase_tailscale
        phase_firewall   # last: if the first run is over Wi-Fi, log in first
        ;;
    *) die "usage: setup.sh [system|wifi|usb|tailscale|firewall|all|poweroff]" ;;
esac

if [ "$NEED_REBOOT" = 1 ]; then
    hdr "Done - rebooting in 5 s to apply changes"
    # Detached, so this SSH command can return 0 and clean up its temp
    # dir before the reboot ends the session.
    if ! systemd-run --quiet --collect --on-active=5 --unit=skidbladnir-reboot \
            systemctl reboot 2>/dev/null; then
        nohup sh -c 'sleep 5; systemctl reboot' >/dev/null 2>&1 &
    fi
else
    hdr "Done"
fi

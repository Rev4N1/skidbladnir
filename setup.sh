#!/bin/bash
# ========================================================
# setup.sh - Raspberry Pi Zero 2 W as a portable
# Tailscale exit node and subnet router for whatever Wi-Fi
# it's on. Runs as root on the Pi; deploy.sh copies it
# over with pi.conf (written from skidbladnir.conf), runs
# it, and deletes both.
#
#   setup.sh                    everything
#   setup.sh system|wifi|usb|tailscale    one step
#   setup.sh poweroff           shut down
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
[ -r "$DIR/pi.conf" ] || die "pi.conf not found next to $0 - run this through ./deploy.sh pi"
# Without CRs, in case the config was last saved on Windows.
. <(tr -d '\r' < "$DIR/pi.conf")

NEED_REBOOT=0
CFG=/boot/firmware/config.txt

# ---- system: update, then strip it down ---------------------------
phase_system() {
    hdr "Packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
    apt-get -qq install unattended-upgrades curl
    apt-get -qq autoremove
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
        > /etc/apt/apt.conf.d/20auto-upgrades
    # Beyond Debian's security updates (the default): Debian's stable
    # updates and the Raspberry Pi archive, where the kernel and firmware
    # come from. A reboot an update needs happens at 04:30.
    cat > /etc/apt/apt.conf.d/52skidbladnir <<'EOF'
// Written by skidbladnir's setup.sh.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates";
        "origin=Raspberry Pi Foundation,codename=${distro_codename}";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
    [ -e /run/reboot-required ] && NEED_REBOOT=1
    ok "up to date; Debian and Raspberry Pi updates install themselves, rebooting at 04:30 if needed"

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
# It joins any Wi-Fi saved with nmcli (README.md).
phase_wifi() {
    hdr "Wi-Fi"
    # Country on the kernel command line: it applies at boot, before
    # wlan0 exists (on the first run it only appears after the reboot).
    cmd=/boot/firmware/cmdline.txt
    if ! grep -qw "cfg80211.ieee80211_regdom=$COUNTRY" "$cmd"; then
        sed -i -e 's/ *cfg80211\.ieee80211_regdom=[^ ]*//' -e "1s/\$/ cfg80211.ieee80211_regdom=$COUNTRY/" "$cmd"
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
# With USB gadget mode on (deploy.sh sdcard), rpi-usb-gadget's switcher
# (rpi-usb-gadget-ics, which must stay ENABLED: it's what brings usb0
# up) serves the laptop an address and is itself at 10.12.194.1. This
# only stops it offering itself as the laptop's gateway and DNS, so the
# laptop keeps its own internet and just gets a link to the Pi.
phase_usb() {
    hdr "USB link to a laptop"
    if ! nmcli -t -f NAME connection show | grep -qx 'USB Gadget (shared)'; then
        warn "USB gadget mode is off (deploy.sh sdcard) - skipped"
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

# ---- tailscale: exit node + whatever Wi-Fi the Pi is on ------------
# Tailscale needs no port forward and works behind any NAT, so the Pi
# works from wherever it is. A NetworkManager hook advertises the Wi-Fi
# network it's on right now, so Tailscale clients reach that whole LAN.
phase_tailscale() {
    hdr "Tailscale"
    if ! command -v tailscale >/dev/null; then
        . /etc/os-release
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get -qq update
        DEBIAN_FRONTEND=noninteractive apt-get -qq install tailscale
    fi
    # No support logging: it buffers logs on the SD card.
    if ! grep -qx 'FLAGS="--no-logs-no-support"' /etc/default/tailscaled 2>/dev/null; then
        sed -i 's/^FLAGS=.*/FLAGS="--no-logs-no-support"/' /etc/default/tailscaled
        grep -qx 'FLAGS="--no-logs-no-support"' /etc/default/tailscaled \
            || echo 'FLAGS="--no-logs-no-support"' >> /etc/default/tailscaled
        systemctl restart tailscaled
    fi
    systemctl enable --now tailscaled >/dev/null 2>&1

    # Exit node and subnet router both need forwarding.
    printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-tailscale.conf
    sysctl -q --system

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

    hook=/etc/NetworkManager/dispatcher.d/90-tailscale-routes
    cat > "$hook" <<'EOF'
#!/bin/sh
# Written by skidbladnir's setup.sh. Advertises the Wi-Fi network the
# Pi is on right now as a Tailscale subnet route.
case "$2" in up|down|dhcp4-change) ;; *) exit 0 ;; esac
routes=$(ip -4 route show proto kernel scope link dev wlan0 2>/dev/null | awk '{print $1}' | paste -sd, -)
# The exit node flag again, or "set" would drop it along with the old routes.
tailscale set --advertise-exit-node --advertise-routes="$routes"
EOF
    chmod 755 "$hook"
    "$hook" wlan0 up || warn "couldn't advertise the Wi-Fi network yet - it follows on the next network change"
    ok "$(tailscale ip -4) as $PI_NAME: exit node + $(ip -4 route show proto kernel scope link dev wlan0 2>/dev/null | awk '{printf "%s ", $1}')"
}

# ---- main ----------------------------------------------------------
case "${1:-all}" in
    system)    phase_system ;;
    wifi)      phase_wifi ;;
    usb)       phase_usb ;;
    tailscale) phase_tailscale ;;
    poweroff)  hdr "Shutting down - wait for the activity to stop, then unplug"; systemctl poweroff; exit 0 ;;
    all)
        phase_system
        phase_wifi
        phase_usb
        phase_tailscale
        ;;
    *) die "usage: setup.sh [system|wifi|usb|tailscale|all|poweroff]" ;;
esac

if [ "$NEED_REBOOT" = 1 ]; then
    hdr "Done - rebooting in 5 s to apply changes"
    sleep 5
    systemctl reboot
else
    hdr "Done"
fi

# Skidbladnir

A Tailscale exit node you carry in your pocket: a Raspberry Pi Zero 2 W that
gives your Tailscale devices the internet connection and the whole LAN of
whatever Wi-Fi it's on. (In Norse myth, Skíðblaðnir is Freyr's ship: it always
has a fair wind, and it folds up to fit in a pocket.)

- **Only the Pi.** It needs USB power and a Wi-Fi, nothing else: no router
  changes, no port forward, no other hardware. Tailscale works behind any NAT,
  CGNAT included.
- **Wherever it is**, your Tailscale devices can use it as an **exit node**,
  so all their traffic (`0.0.0.0/0`) leaves from there. They can also reach
  the **whole LAN** of its Wi-Fi: it advertises that network as a subnet
  route, and updates it every time it moves.
- **Your laptop's cable to it.** Plug a laptop into its USB port and you're
  connected to the Pi at `10.12.194.1`, to change its Wi-Fi or anything else,
  even when it has no network at all.
- **Nothing listens to the Wi-Fi except Tailscale.** The Pi's own SSH is open
  on the USB cable and the tailnet only, so a hotel LAN can't reach it;
  Tailscale's access controls decide who reaches what.
- **Built to run unattended for years.** Stripped down to what it uses, with
  logs and swap in RAM so the SD card barely gets written. It updates itself
  (Debian, the Raspberry Pi kernel and firmware, Tailscale), reboots at 04:30
  when an update needs it, and a hardware watchdog reboots it if it ever
  hangs. A Wi-Fi that drops is retried forever.

Everything is set up from your PC with one command, `deploy.sh`, and every step
is safe to re-run.

**Quick start.** Flash and prepare the card (§3), then:

```bash
cp -n skidbladnir.conf.example skidbladnir.conf   # fill in every CHANGE_ME
./deploy.sh                                       # with the Pi booted
```

## 1. What you need

- **A Raspberry Pi Zero 2 W** and a micro-SD card, with
  [Raspberry Pi Imager](https://www.raspberrypi.com/software/) 2.x.
- **A data USB cable** (micro-USB to your laptop), and any USB power.
- **A [Tailscale](https://tailscale.com) account.**
- **PC:** Linux with `bash` and `ssh`, for `deploy.sh`. `sshpass` is
  recommended, so it types the password for you (`sudo dnf install sshpass`).
  Every step also shows how to do it by hand, with the OpenSSH client (`ssh`,
  `scp`) in PowerShell.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n skidbladnir.conf.example skidbladnir.conf
```

Fill in every `CHANGE_ME`. `skidbladnir.conf` is git-ignored and holds the
Pi's password, so keep a backup somewhere safe. Pick a strong `PI_PASSWORD`:
the first deploy (often over Wi-Fi) and the USB cable both use it, and until
the `firewall` step has run, so does any Wi-Fi network the Pi joins.

## 3. First time (about 15 minutes)

1. **Flash the card** with Raspberry Pi Imager: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set:
   - the hostname (`PI_NAME`), and the user and password from
     `skidbladnir.conf`,
   - your Wi-Fi and its country,
   - **enable SSH**.

2. **Turn on USB gadget mode,** for the laptop cable. Imager's `user-data`
   (on the card's `bootfs` partition) has no `rpi:` section, so this adds one
   at the end. With the card still in the PC, and opened in your file manager
   so it's mounted:

   ```bash
   f="$(findmnt -nro TARGET --source LABEL=bootfs | head -n1)/user-data"; grep -q enable_usb_gadget "$f" || printf 'rpi:\n  enable_usb_gadget: true\n' | sudo tee -a "$f" >/dev/null; sync; tail -n 3 "$f"
   ```

   The last two lines it shows must be `rpi:` and `  enable_usb_gadget: true`.

   By hand: open `user-data` on the card's `bootfs` drive in a text editor and
   add these two lines at the end, with spaces, not tabs:

   ```yaml
   rpi:
     enable_usb_gadget: true
   ```

3. **Boot it:** put the card in, plug the Pi's **USB** port (the inner one,
   not `PWR`) into your PC, and wait 2–3 minutes. Windows needs the
   [Raspberry Pi RNDIS driver](https://github.com/raspberrypi/rpi-usb-gadget)
   once; Linux needs nothing.

4. **Set it up:**

   ```bash
   ./deploy.sh
   ```

   It finds the Pi by itself: the USB cable first (at `10.12.194.1`), then
   Wi-Fi (at `<PI_NAME>.local`, or `PI_HOST`), then its Tailscale name
   `<PI_NAME>` (from any device on your tailnet). It checks the hostname
   before touching anything, so it won't configure a different Pi by mistake.
   It updates the Pi, strips it down, sets up Wi-Fi and the laptop
   cable, installs Tailscale, then closes SSH on Wi-Fi. Without `TS_AUTHKEY`,
   it prints a login link: open it and approve the Pi. It reboots at the end
   if needed. The same command is the maintenance run after an update or a
   config change.

   After this, the Pi's SSH answers on the **cable and Tailscale only**.
   Over the tailnet, `ssh <PI_USER>@<PI_NAME>`.

   By hand: copy `setup.sh` and your config to the Pi, then run it; the same
   command deletes both after. Use `<PI_NAME>.local`, or `10.12.194.1` over
   the cable. SSH asks the Pi's password, and `sudo` once more:

   ```powershell
   scp setup.sh skidbladnir.conf <PI_USER>@<PI_NAME>.local:
   ```

   ```powershell
   ssh -t <PI_USER>@<PI_NAME>.local "mv skidbladnir.conf pi.conf && sudo bash setup.sh; rm -f setup.sh pi.conf"
   ```

   For one step (advanced), run it on the Pi, for example
   `sudo bash setup.sh tailscale`.

5. **Approve it in the [admin console](https://login.tailscale.com/admin/machines):**
   on the Pi's row, *Edit route settings…* → tick **Use as exit node** and its
   LAN route. Then *Disable key expiry*, so it never needs a new login.

6. **Use it:** in the Tailscale app on any device, pick the Pi as exit node.
   The LAN behind it works with or without that.

**Every new Wi-Fi is a new route to approve.** To skip that, let your tailnet
approve them by itself. In the admin console, open
[*Access controls*](https://login.tailscale.com/admin/acls/file) (the JSON
editor) and add this block inside the outer `{ }`, after the `"ssh"` section's
closing `],`. Put your Tailscale login in place of `you@example.com`: it's
shown under the Pi's name on the *Machines* page.

```json
	"autoApprovers": {
		"routes": {
			"10.0.0.0/8":     ["you@example.com"],
			"172.16.0.0/12":  ["you@example.com"],
			"192.168.0.0/16": ["you@example.com"],
		},
		"exitNode": ["you@example.com"],
	},
```

Save. The default policy's allow-all grant already lets your devices use the
routes, so nothing else changes. It only approves routes advertised from now
on: one already waiting needs approving by hand once (step 5).

## 4. Taking it somewhere

Plug the Pi into anything that gives USB power. It joins the first saved Wi-Fi
in range, and Tailscale finds it there.

### Saving a Wi-Fi

Connect your laptop to the Pi's **USB** port (the inner one, which powers it
too) and wait 2 minutes. The laptop gets an address on that cable, but keeps
its own internet. Then, on the Pi (`ssh <PI_USER>@10.12.194.1`, or over
Tailscale from anywhere), with the network in range:

```bash
sudo nmcli device wifi connect "Hotel Wifi" password 'its password'
```

`nmcli device wifi list` shows what the Pi can see. To save one ahead of time,
out of range:

```bash
sudo nmcli connection add type wifi ifname wlan0 con-name "Hotel Wifi" ssid "Hotel Wifi" wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'its password'
```

To see what's saved and connected, and to forget one:

```bash
nmcli connection show
```

```bash
sudo nmcli connection delete "Hotel Wifi"
```

A Wi-Fi with a captive portal (a sign-in page) won't work: the Pi has no
browser.

### No Wi-Fi at all: through the laptop

If the laptop shares its own connection on that cable (Linux: a
NetworkManager connection with `ipv4.method shared` on the Pi's USB
interface; Windows: Internet Connection Sharing), the Pi takes an address and
internet from the laptop instead, and prefers it over Wi-Fi. It's then at
`<PI_NAME>.local`, not `10.12.194.1`.

## 5. Later

- **Check on it**, from the PC over the cable or the tailnet:

  ```bash
  # over the tailnet, use <PI_USER>@<PI_NAME> instead of the cable address
  ssh <PI_USER>@10.12.194.1 '
    uptime
    ip -br addr
    nmcli -t -f NAME,DEVICE connection show --active
    tailscale status
    tailscale debug prefs | grep -i route
    vcgencmd measure_temp
    df -h /
  '
  ```

- **After editing `skidbladnir.conf`,** run `./deploy.sh` again. Only what
  differs changes.
- **Reflashing the SD card:** remove the old Pi in the admin console, then do
  section 3 again.

## How it works

```
skidbladnir.conf.example   every setting, in the order you fill them in
deploy.sh                  the one command you run on the PC
setup.sh                   runs on the Pi, one step at a time
```

| `setup.sh` step | |
|---|---|
| `system` | Updates, then keeps updating itself: Debian security and stable updates and the Raspberry Pi archive (kernel, firmware), rebooting at 04:30 when one needs it, and removing old kernels so the card doesn't fill up. The hardware watchdog reboots it after a 14 s hang. Logs in RAM only (swap already is), so the SD card barely gets written. Bluetooth, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `wifi` | Wi-Fi and its country come from Imager; this turns power saving off (lower latency), and a dropped network retried forever. |
| `usb` | Keeps `rpi-usb-gadget`'s switcher **enabled** (it's what brings `usb0` up), so a laptop on the cable gets an address with the Pi at `10.12.194.1`. Stops the Pi offering itself as the laptop's gateway or DNS. Skipped if the card wasn't prepared first (section 3, step 2). |
| `tailscale` | Installs Tailscale with auto-updates and without support logging (which writes to the SD card), and logs in as `PI_NAME`, as an exit node. A systemd unit (`skidbladnir-routes`) advertises the Wi-Fi network as a route; a NetworkManager hook starts it on every change. Also enables forwarding, keeping IPv6 router advertisements working. |
| `firewall` | Puts `/etc/nftables.conf` in place: SSH is accepted on `usb0` and `tailscale0` only and dropped everywhere else. Established connections are kept. Nothing else on the host is filtered. It only ever replaces its own table: stopping or restarting `nftables` (an upgrade does) never touches Tailscale's rules. |

`./deploy.sh` runs them all; on the Pi, `sudo bash setup.sh <step>` runs one.

- **The Pi only gets what it needs.** `setup.sh` and its settings travel
  inside the SSH command, and are deleted when it finishes. The password stays
  on your PC.
- **Passwords, no SSH keys.** `deploy.sh` logs in with `PI_PASSWORD`. With
  `sshpass` installed it types it for you; without it, SSH asks. `sudo` is
  answered from `PI_PASSWORD` either way. That is also why the firewall keeps
  SSH off Wi-Fi: a password is the only thing between a hotel LAN and the Pi.
- **Speed:** Tailscale encrypts in userspace on a 1 GHz core over 2.4 GHz
  Wi-Fi, so expect tens of Mbps. Plenty for a phone, or for reaching a LAN.

## Limits

- **2.4 GHz only.** The Zero 2 W has no 5 GHz radio, so a 5 GHz-only network
  can't be joined.
- **Captive portals don't work:** the Pi has no browser to click through.
- **LAN routes are IPv4.** The exit node carries both families; the advertised
  subnet route is the IPv4 network it is on.
- **No clock when it boots offline.** There is no RTC; the time is wrong until
  NTP reaches a server, which can delay the first TLS connection.
- **One radio.** It can be a station or an access point, not both at once.

## Troubleshooting

- **Can't reach it over Wi-Fi:** expected after the first deploy. Use the cable
  (`ssh <PI_USER>@10.12.194.1`, which `./deploy.sh` also tries) or the tailnet
  (`ssh <PI_USER>@<PI_NAME>`). The cable is also the way in when the Pi has no
  network at all.
- **The first run had no internet:** package updates and Tailscale are skipped,
  the firewall stays off (so Wi-Fi SSH still works), and any needed reboot still
  happens. Set up Wi-Fi or the laptop cable, then run `./deploy.sh` again.
- **Reflashed the card and it configures the old Pi:** Tailscale still gives
  the old node the name `<PI_NAME>`, and the new card becomes `<PI_NAME>-1` (or
  waits for a rename). Remove the old node in the admin console, then run
  `./deploy.sh` again. The hostname check cannot tell two cards with the same
  name apart.
- **The laptop never sees the USB link:** the `rpi-usb-gadget-ics` service got
  disabled. Put the SD card in a Linux PC, open it in the file manager, and
  re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

  This one needs Linux: only Linux reads the card's system partition.

- **Tailscale works, but nothing passes through the Pi:** the exit node or the
  route isn't approved yet (section 3, step 5). On the Pi, `tailscale status`
  and `tailscale debug prefs` show what it advertises.

## License

[MIT](LICENSE)

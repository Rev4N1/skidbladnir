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
- **No firewall on the Pi:** Tailscale's access controls decide who reaches
  what.
- **Stripped down** to what it uses, for free RAM and SD-card life. It updates
  itself, Tailscale included.

Everything is set up from your PC with one command, `deploy.sh`, and every step
is safe to re-run.

## 1. What you need

- **A Raspberry Pi Zero 2 W** and a micro-SD card, with
  [Raspberry Pi Imager](https://www.raspberrypi.com/software/) 2.x.
- **A data USB cable** (micro-USB to your laptop), and any USB power.
- **A [Tailscale](https://tailscale.com) account.**
- **PC:** Linux with `bash`, `ssh` and `scp`, for `deploy.sh`. `sshpass` is
  recommended, so even the first login is silent (`sudo dnf install sshpass`).
  Every step also shows how to do it by hand, with the OpenSSH client (`ssh`,
  `scp`) in PowerShell.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n skidbladnir.conf.example skidbladnir.conf
```

Fill in every `CHANGE_ME`. `skidbladnir.conf` is git-ignored and holds the
Pi's password, so keep a backup somewhere safe. Pick a strong `PI_PASSWORD`:
SSH listens on every network the Pi joins.

## 3. First time (about 15 minutes)

1. **Flash the card** with Raspberry Pi Imager: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set:
   - the hostname (`PI_NAME`), and the user and password from
     `skidbladnir.conf`,
   - your Wi-Fi and its country,
   - **enable SSH**.

2. **Turn on USB gadget mode,** for the laptop cable. With the card still in
   the PC, and opened in your file manager so it's mounted:

   ```bash
   ./deploy.sh sdcard
   ```

   By hand: open the card's `bootfs` drive and open `user-data` in a text
   editor. If it has an `rpi:` line, add `enable_usb_gadget: true` under it,
   indented like the lines below it. Otherwise, add these two lines at the
   end, with spaces, not tabs:

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
   ./deploy.sh pi
   ```

   It reaches the Pi over Wi-Fi at `<PI_NAME>.local` (or `PI_HOST`); add
   `--usb` to go over the cable instead. It updates the Pi, strips it down,
   sets up Wi-Fi and the laptop cable, and installs Tailscale. Without
   `TS_AUTHKEY`, it prints a login link: open it and approve the Pi. It
   reboots at the end if needed.

   By hand: copy `setup.sh` and your config to the Pi, then run it; the same
   command deletes both after. Use `<PI_NAME>.local`, or `10.12.194.1` over
   the cable. SSH asks the Pi's password, and `sudo` once more:

   ```powershell
   scp setup.sh skidbladnir.conf <PI_USER>@<PI_NAME>.local:
   ```

   ```powershell
   ssh -t <PI_USER>@<PI_NAME>.local "mv skidbladnir.conf pi.conf && sudo bash setup.sh; rm -f setup.sh pi.conf"
   ```

   For one step, put it after `setup.sh`, for example
   `sudo bash setup.sh tailscale`.

5. **Approve it in the [admin console](https://login.tailscale.com/admin/machines):**
   on the Pi's row, *Edit route settings…* → tick **Use as exit node** and its
   LAN route. Then *Disable key expiry*, so it never needs a new login.

6. **Use it:** in the Tailscale app on any device, pick the Pi as exit node.
   The LAN behind it works with or without that.

**Every new Wi-Fi is a new route to approve.** To skip that, let your tailnet
approve them by itself: in the admin console, *Access controls*, add this to
the policy file, with your Tailscale login:

```json
"autoApprovers": {
  "routes": {
    "10.0.0.0/8":     ["you@example.com"],
    "172.16.0.0/12":  ["you@example.com"],
    "192.168.0.0/16": ["you@example.com"]
  },
  "exitNode": ["you@example.com"]
}
```

## 4. Taking it somewhere

Plug the Pi into anything that gives USB power. It joins the first saved Wi-Fi
in range, and Tailscale finds it there.

### Saving a Wi-Fi

Connect your laptop to the Pi's **USB** port (the inner one, which powers it
too) and wait 2 minutes. The laptop gets an address on that cable, but keeps
its own internet. Then:

```bash
ssh <PI_USER>@10.12.194.1
```

On the Pi, with the network in range:

```bash
sudo nmcli device wifi connect "Hotel Wifi" password 'its password'
```

Or saved ahead of time, out of range:

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

- **After editing `skidbladnir.conf`,** run `./deploy.sh pi` again. Only what
  differs changes.
- **Reflashing the SD card:** remove the old Pi in the admin console, then do
  section 3 again.

## How it works

```
skidbladnir.conf.example   every setting, in the order you fill them in
deploy.sh                  the one command you run on the PC (./deploy.sh for help)
setup.sh                   runs on the Pi, one step at a time
```

| `setup.sh` step | |
|---|---|
| `system` | Updates, with automatic security updates from then on. Logs and swap in RAM only, so the SD card barely gets written. Bluetooth, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `wifi` | Wi-Fi on, with the country from `COUNTRY` and power saving off. |
| `usb` | Keeps `rpi-usb-gadget`'s switcher **enabled** (it's what brings `usb0` up), so a laptop on the cable gets an address with the Pi at `10.12.194.1`. Stops the Pi offering itself as the laptop's gateway or DNS. Skipped without `deploy.sh sdcard`. |
| `tailscale` | Installs Tailscale with auto-updates and logs in as `PI_NAME`, as an exit node. A NetworkManager hook (`/etc/NetworkManager/dispatcher.d/90-tailscale-routes`) advertises the Wi-Fi network as a route, whenever it changes. |

`./deploy.sh pi` runs them all; `./deploy.sh pi <step>` runs one.

- **The Pi only gets what it needs.** `setup.sh` and its settings travel
  inside the SSH command, and are deleted when it finishes. The password stays
  on your PC.
- **No password prompts.** `deploy.sh` logs in with its own SSH key
  (`~/.ssh/skidbladnir_ed25519`, created on first run), installed once using
  `PI_PASSWORD`. That's silent with `sshpass`, and asks once without it.
  `sudo` is answered from `PI_PASSWORD` too.
- **Speed:** Tailscale encrypts in userspace on a 1 GHz core over 2.4 GHz
  Wi-Fi, so expect tens of Mbps. Plenty for a phone, or for reaching a LAN.

## Troubleshooting

- **Can't reach it over Wi-Fi:** plug it into your laptop and
  `ssh <PI_USER>@10.12.194.1`. Over Tailscale, `ssh <PI_USER>@<PI_NAME>` works
  from anywhere.
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

# Skidbladnir

A Tailscale exit node you carry in your pocket: a Raspberry Pi Zero 2 W that
gives your Tailscale devices the internet connection and the whole LAN of
wherever you plug it in. (In Norse myth, Skíðblaðnir is Freyr's ship: it always
has a fair wind, and it folds up to fit in a pocket.)

- **At home** it plugs into your router's USB port, which powers it and shows
  it as a LAN port. No Wi-Fi, no extra cables, no power supply.
- **Anywhere else**, give it USB power and it joins a Wi-Fi you saved.
- **Wherever it is**, your Tailscale devices can use it as an **exit node**,
  so all their traffic (`0.0.0.0/0`) leaves from there. They can also reach
  the **whole LAN** it's on: it advertises the networks it's connected to as
  subnet routes, and updates them every time it moves.
- **Nothing to open on the router:** Tailscale needs no port forward and works
  behind any NAT, CGNAT included. There's no firewall on the Pi; Tailscale's
  access controls decide who reaches what.
- **Stripped down** to what it uses, for free RAM and SD-card life. It updates
  itself, Tailscale included.

Everything is set up from your PC with one command, `deploy.sh`, and every step
is safe to re-run.

## 1. What you need

- **A Raspberry Pi Zero 2 W** and a micro-SD card, with
  [Raspberry Pi Imager](https://www.raspberrypi.com/software/) 2.x.
- **A data USB cable** (micro-USB to your PC's or router's port).
- **A [Tailscale](https://tailscale.com) account.**
- **PC:** Linux with `bash`, `ssh` and `scp`. `sshpass` is recommended, so even
  the first login is silent (`sudo dnf install sshpass`). On Windows,
  `deploy.sh` runs in Git Bash.
- **At home (optional):** an [OpenWrt](https://openwrt.org) 25.12 router with
  a USB port. Without one, the Pi lives on Wi-Fi only.

## 2. Configure

Every setting and secret lives in one file:

```bash
cp -n skidbladnir.conf.example skidbladnir.conf
```

Fill in every `CHANGE_ME`. `skidbladnir.conf` is git-ignored and holds the
Pi's password, so keep a backup somewhere safe. Pick a strong `PI_PASSWORD`:
SSH listens on every network the Pi joins.

## 3. First time (about 20 minutes)

1. **Flash the card** with Raspberry Pi Imager: *Raspberry Pi Zero 2 W* →
   *Raspberry Pi OS Lite (64-bit)* (Trixie). In Customisation, set the
   hostname (`PI_NAME`), the user and password from `skidbladnir.conf`, and
   **enable SSH**. Leave Wi-Fi unconfigured if it'll live on a router's USB
   port at home. If it'll live on Wi-Fi only, set your home Wi-Fi (and its
   country) here.

2. **Turn on USB-Ethernet mode.** With the card still in the PC, and opened in
   your file manager so it's mounted:

   ```bash
   ./deploy.sh sdcard
   ```

   Without this, the Pi's USB port only takes power.

3. **Boot it on your PC.** Use a cable from the Pi's **USB** port (the inner
   one, not `PWR`) to the PC, and wait 2–3 minutes. Linux needs nothing;
   Windows needs the
   [Raspberry Pi RNDIS driver](https://github.com/raspberrypi/rpi-usb-gadget)
   once.

4. **Make it a plain network client:**

   ```bash
   ./deploy.sh pi --usb network
   ```

   This also pins its USB MACs and records them in `skidbladnir.conf`.

5. **Give it a way online,** before it leaves the PC:

   - **On an OpenWrt router:** let the router take it. This installs the
     USB-Ethernet drivers and puts `usb0` in the LAN bridge (it asks the
     router's root password):

     ```bash
     ./deploy.sh router
     ```

   - **Wi-Fi only:** nothing to do; it joins the Wi-Fi you set in Imager.

6. **Move it:**

   ```bash
   ./deploy.sh pi --usb poweroff
   ```

   Wait a few seconds, then plug it into the router's USB port, or into any
   USB power if it's going on Wi-Fi.

7. **Set up everything else:**

   ```bash
   ./deploy.sh pi
   ```

   It reaches the Pi at `<PI_NAME>.local` (or `PI_HOST`). It updates the Pi,
   strips it down, sets up Wi-Fi and installs Tailscale. Without `TS_AUTHKEY`,
   it prints a login link: open it and approve the Pi. It reboots at the end
   if needed.

8. **Approve it in the [admin console](https://login.tailscale.com/admin/machines):**
   on the Pi's row, *Edit route settings…* → tick **Use as exit node** and its
   LAN route. Then *Disable key expiry*, so it never needs a new login.

9. **Use it:** in the Tailscale app on any device, pick the Pi as exit node.
   The LAN behind it works with or without that.

**Every new network is a new route to approve.** To skip that, let your
tailnet approve them by itself: in the admin console, *Access controls*, add
this to the policy file, with your Tailscale login:

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

Away from home, plug the Pi into anything that gives USB power. It joins the
first saved Wi-Fi in range, and Tailscale finds it there.

### Saving a Wi-Fi

Connect your laptop to the Pi's **USB** port (the inner one, which powers it
too) and wait 2 minutes. Then:

```bash
ssh <PI_USER>@<PI_NAME>.local
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

**If `<PI_NAME>.local` doesn't resolve,** your laptop is only looking it up
over IPv4 (Fedora's default). On a Linux laptop, share its connection on that
cable once: the Pi then gets an IPv4 address from the laptop, and internet
through it too. `HOST_MAC` is in `skidbladnir.conf`:

```bash
nmcli connection add type ethernet con-name skidbladnir-usb ethernet.mac-address <HOST_MAC> ipv4.method shared ipv6.method link-local
```

A Wi-Fi with a captive portal (a sign-in page) won't work: the Pi has no
browser.

## 5. Later

- **After editing `skidbladnir.conf`,** run `./deploy.sh pi` again. Only what
  differs changes.
- **After a router flash,** run `./deploy.sh router` again: a flash drops the
  USB-Ethernet drivers.
- **Reflashing the SD card:** remove the old Pi in the admin console, then do
  section 3 again. `skidbladnir.conf` already holds its MACs, so it comes back
  as the same device.
- **A fixed IP at home:** give its MAC (`PI_MAC`) a static lease on your
  router, and set `PI_HOST` to that IP.

## How it works

```
skidbladnir.conf.example   every setting, in the order you fill them in
deploy.sh                  the one command you run on the PC (./deploy.sh for help)
setup.sh                   runs on the Pi, one step at a time
openwrt/usb-gadget.sh      runs on an OpenWrt router: drivers + usb0 in the LAN bridge
```

| `setup.sh` step | |
|---|---|
| `network` | Pins the USB MACs (random on every boot otherwise). Makes `usb0` a DHCP client with IPv6 link-local. Keeps `rpi-usb-gadget`'s auto-switcher **enabled**, since it's what brings `usb0` up at boot. It picks the "shared" profile, which as shipped would be a DHCP server on your LAN, so that profile is turned into a client. |
| `system` | Updates, with automatic security updates from then on. Logs and swap in RAM only, so the SD card barely gets written. Bluetooth, LED, display driver, audio and idle consoles off; GPU memory at its minimum. |
| `wifi` | Wi-Fi on, with the country from `COUNTRY` and power saving off. When `usb0` is connected, NetworkManager prefers it. |
| `tailscale` | Installs Tailscale with auto-updates and logs in as `PI_NAME`, as an exit node. A NetworkManager hook (`/etc/NetworkManager/dispatcher.d/90-tailscale-routes`) advertises the networks on `usb0` and `wlan0` as routes, whenever they change. |

`./deploy.sh pi` runs them all; `./deploy.sh pi <step>` runs one.

- **The Pi only gets what it needs.** `setup.sh` and its settings travel
  inside the SSH command, and are deleted when it finishes. The password stays
  on your PC.
- **No password prompts.** `deploy.sh` logs in with its own SSH key
  (`~/.ssh/skidbladnir_ed25519`, created on first run), installed once using
  `PI_PASSWORD`. That's silent with `sshpass`, and asks once without it.
  `sudo` is answered from `PI_PASSWORD` too.
- **Speed:** Tailscale encrypts in userspace on a 1 GHz core, so expect tens
  of Mbps, less over Wi-Fi. Plenty for a phone, or for reaching a LAN.

## Troubleshooting

- **Can't reach it over the network:** plug it into your laptop and
  `ssh <PI_USER>@<PI_NAME>.local` (see above). Over Tailscale,
  `ssh <PI_USER>@<PI_NAME>` works from anywhere.
- **The Pi boots but its USB link never comes up** (the router shows `usb0`
  as `down`, with the Pi's LED off you can't tell otherwise): the
  `rpi-usb-gadget-ics` service got disabled. Put the SD card in a Linux PC,
  open it in the file manager, and re-enable it on the card:

  ```bash
  root=$(findmnt -nro TARGET --source LABEL=rootfs | head -n1) && sudo ln -sfn /usr/lib/systemd/system/rpi-usb-gadget-ics.service "$root/etc/systemd/system/multi-user.target.wants/rpi-usb-gadget-ics.service" && sync
  ```

- **Tailscale works, but nothing passes through the Pi:** the exit node or the
  route isn't approved yet (section 3, step 8). On the Pi, `tailscale status`
  and `tailscale debug prefs` show what it advertises.

## Windows

`deploy.sh` runs in Git Bash, except `sdcard`, which needs Linux. To do it by
hand, open the card's `bootfs` drive and open `user-data` in Notepad:
- If it has an `rpi:` line, add `enable_usb_gadget: true` under it, indented
  like the lines below it.
- Otherwise, add these two lines at the end, with spaces, not tabs:

```yaml
rpi:
  enable_usb_gadget: true
```

## Related

[Bifrost](https://github.com/Rev4N1/bifrost) sets up the OpenWrt routers
themselves: main router, dumb APs with fast roaming, a WireGuard server, and a
Telegram home/away bot.

## License

[MIT](LICENSE)

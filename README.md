# Ubuntu Full Stack Setup

Installs Node.js, React, Node-RED, Python, Docker, and Beremiz on fresh Ubuntu,
applies client branding (wallpaper + Plymouth boot splash), installs RustDesk for
remote support, and boots the machine into a full-screen **kiosk**.

## Install (IPC — full stack)

Nothing is hardcoded — you pass the kiosk URL (and PLC address, if using the
door logger) on the command line. Change only the first two lines:

```bash
URL='https://DASHBOARD_HOST/'   # <-- kiosk target
PLC=SET_PLC_IP_HERE                                         # <-- Modbus PLC (door logger)
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/setup.sh -o setup.sh && \
chmod +x setup.sh && \
sudo APPLIANCE_URL="$URL" PLC_HOST="$PLC" ./setup.sh && \
sudo reboot
```

`DASHBOARD_HOST` is the TaskOrder dashboard's address — **it is deliberately
not written in this public repo**; get it from the project's private notes.
The dashboard is served by nginx on 443 with a self-signed certificate (the
kiosk accepts it automatically; 80 redirects to 443). Unauthenticated hits
land on `/login` and bounce back to the path you gave, so `https://DASHBOARD_HOST/`
lands on the main dashboard after sign-in, and
`https://DASHBOARD_HOST/login?callbackUrl=%2Fwork-orders` lands on the work
orders board. Tablets need internet access (Wi-Fi) to reach it. Old/decommissioned
hosts must not be used — check the private notes for the current one.

`setup.sh` fetches every numbered script in `scripts/` and runs them in order;
a failing step is reported and skipped, never silently aborting the rest.
`APPLIANCE_URL` is what the kiosk opens (full URL — port, path, query all
fine). `APPLIANCE_IP=<ip>` is accepted as shorthand for `http://<ip>`.

## Tablet install (kiosk viewer only)

For Linux tablets that just display the portal — no Node-RED/Docker/Beremiz,
no door logger (that stays on the IPC). Change only the `URL=` line:

```bash
URL='https://DASHBOARD_HOST/'   # <-- change this only
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/tablet-setup.sh -o tablet-setup.sh && \
chmod +x tablet-setup.sh && \
sudo APPLIANCE_URL="$URL" ./tablet-setup.sh && \
sudo reboot
```

Hand-typing because copy/paste isn't available? Use the hyphen-free alias
(messaging apps mangle hyphens into dashes):

```
sudo apt update
sudo apt install curl
wget https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/tablet.sh
sudo APPLIANCE_URL='https://DASHBOARD_HOST/' bash tablet.sh
sudo reboot
```

`tablet-setup.sh` runs: system update → wallpaper + Plymouth branding →
RustDesk (viewer + remote-support host in one) → Chrome kiosk → tablet tweaks →
updates off → VS Code.

Tablet tweaks (`scripts/tablet_tweaks.sh`, tablet profile only):

- Rotation locked by default, so a mis-mounted accelerometer can't flip
  the kiosk screen on its own. For a handheld unit that should follow how
  it is held, pass `LOCK_ROTATION=0`.
- **Onboard** is the kiosk's touch keyboard: it pops up when a portal text
  field is tapped (a floating keyboard icon opens it by hand). Chrome runs
  under X11 so Onboard, and any USB keyboard, can type into it. USB
  autosuspend is off so a plugged-in keyboard or mouse doesn't go dead.
- **Tablet set up before this?** Update its keyboard handling from any
  terminal on it (only dots and slashes to type on the touch keyboard):

  ```bash
  wget raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/kbfix.sh
  sudo bash kbfix.sh      # re-applies kiosk + tablet tweaks, then reboots
  ```
- Suspend made impossible: power button ignored, sleep targets masked,
  no screen dim on battery. Hold the power button for a hard power-off.
- No notification banners over the kiosk; GNOME welcome tour removed.

Requirements: x86_64 tablet (check before wiping Windows — no ARM),
Ubuntu Desktop 24.04 LTS, 4 GB RAM minimum.

### One-stick install (no typing on the tablet)

`usb/make-kiosk-usb.ps1` makes a USB stick that does the whole job: boot the
tablet from it and it erases the internal drive, installs Ubuntu 24.04 with
the `operator` account and the Wi-Fi, and powers off. Pull the stick and
power on: the first boot runs `tablet.sh` (latest code from GitHub) by itself
and reboots into the kiosk. Nobody has to log in or type.

On a Windows PC, in **PowerShell as Administrator**, from a copy of this repo:

```powershell
powershell -ExecutionPolicy Bypass -File usb\make-kiosk-usb.ps1 -ApplianceUrl 'https://DASHBOARD_HOST/'
```

It asks for the Wi-Fi name and password and the `operator` password, lists
the USB drives, and erases only the one you pick after you type `ERASE`.
Needs a stick of 8 GB or more and Git for Windows (for `openssl`); the Ubuntu
ISO is downloaded and checked if it isn't in Downloads.

- The stick's boot menu starts the automatic install after 10 seconds, so no
  keyboard is needed on the tablet. It only erases an **S101AYCR110**
  (checked in firmware) and stops with an error on anything else;
  `-Model ''` removes that check.
- It **powers off** when the install is done. Pull the stick before powering
  on, or it installs again.
- First-boot setup takes ~30–40 min with the login screen showing; leave it.
  No internet yet? It retries on every boot. Log:
  `/var/log/kiosk-firstboot.log` (it also prints the RustDesk ID).
- The Wi-Fi password is on the stick in plain text; the `operator` password
  only as a hash. Wipe or keep the stick safe afterwards.
- Other options: `-TimeZone` (default `America/New_York`), `-Hostname`,
  `-RustDeskPassword`, `-DiskNumber`, `-TargetFolder` (build into a folder
  instead of a stick).

### Before wiping Windows on a rugged tablet (checklist)

Do these while Windows is still on the device — they can't be done afterwards.

1. **Confirm the CPU is x86_64.** Settings → System → About → "System type"
   must say *x64-based processor*. (Or on the Windows setup screen press
   Shift+F10 for a command prompt and run `echo %PROCESSOR_ARCHITECTURE%` —
   it must print `AMD64`.) If it says ARM, stop: this repo won't work.
2. **Put the barcode scanner module in USB keyboard-wedge (HID-KBW) mode**
   with a suffix of Enter/CR. The mode is stored inside the scanner module,
   so it survives the OS wipe. Use the vendor's scan-to-configure sheet or
   its Windows scanner tool; note the module brand from Device Manager
   (Honeywell, Newland, Zebra, …) — you'll want it if the dashboard talks to
   the scanner directly over serial/HID instead of as a keyboard.
3. **Find the boot-menu key** (usually F7, F12, Esc or Del on these units)
   and make sure Secure Boot is off or set to "Other OS" in the BIOS.
   Ubuntu boots with Secure Boot on, but many rugged tablets need it off
   for the USB installer to appear in the boot menu.
4. **Make the installer USB on a Mac:** download the Ubuntu Desktop 24.04
   LTS ISO, then either use balenaEtcher, or in Terminal:
   `diskutil list` → find the stick (e.g. `disk4`) →
   `diskutil unmountDisk /dev/disk4` →
   `sudo dd if=~/Downloads/ubuntu-24.04*-desktop-amd64.iso of=/dev/rdisk4 bs=4m status=progress`
   → `diskutil eject /dev/disk4`. A USB-C stick plugs straight in; a USB-A
   stick needs a USB-C hub (pick a hub with power pass-through if the
   tablet has a single USB-C port).
5. Boot the tablet from the stick, choose *Erase disk and install Ubuntu*,
   create the kiosk user (e.g. `operator`), then **click Install on the
   "Review your choices" screen and wait for "Installation complete"** —
   nothing is written to the disk before that, so stopping earlier boots
   back into the installer every time. Restart, **pull the stick out as soon
   as the screen goes black** (the "remove the installation medium" prompt
   is often skipped), connect Wi-Fi, then run the tablet install command
   above. **Note whether the installer screen was the right way round** —
   that decides the orientation step below.

### Orientation: making screen, splash and touch all agree

Rugged tablets often have the panel mounted rotated or upside down relative
to what Linux assumes, and some have the touch sensor mirrored against the
panel. Fix it in this order, and **never by flipping the brand images** (the
splash assets in `client-brand/` are stored right-way-up; the previous copies
were pre-flipped for one upside-down unit and have been corrected):

1. **Whole display wrong way up or sideways at every stage (splash, login,
   kiosk)?** That's the panel. Re-run the tablet tweaks with `BOOT_ROTATION`
   — this sets the kernel `panel_orientation`, so the Plymouth splash, GDM,
   the GNOME session **and the touch mapping** all rotate together.

   Pick the value from what the **Ubuntu installer screen** looks like —
   that is the picture before any fix. Don't guess from the hardware: the
   S101AYCR110 has a native 1200×1920 portrait panel, yet its installer
   comes up the right way round, and forcing `left` there turned a correct
   screen sideways.

   | installer screen is… | use |
   | --- | --- |
   | correct | **nothing** — leave `BOOT_ROTATION` out (the S101AYCR110 case) |
   | sideways (90° off) | `BOOT_ROTATION=left` — if it then lands upside down, re-run with `right` |
   | upside down (180°) | `BOOT_ROTATION=inverted` |

   ```bash
   curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/scripts/tablet_tweaks.sh \
     | sudo BOOT_ROTATION=left bash      # only if sideways (or: right | inverted)
   sudo reboot
   ```

   Rotation stays locked either way (the tablet tweaks lock it by default);
   add `LOCK_ROTATION=0` if the unit is handheld and should auto-rotate.

   Applying `BOOT_ROTATION` also **clears older fixes that would now
   double-correct**: the `touch_fix.sh` rule, the `rotate_fix.sh` sensor
   correction, and any saved GNOME display layout (`monitors.xml` for each
   user and the login screen — renamed to `monitors.xml.bak-<date>`, not
   deleted). Re-running with a different value is safe; the previous
   rotation is replaced, not stacked. Don't rotate the display from GNOME
   Settings afterwards — that saves a new `monitors.xml` on top.

   **Only the boot splash is upside down; login and kiosk are fine?** That's
   not the panel — don't use `BOOT_ROTATION`, it would turn the desktop too.
   The splash has its own switch, `SPLASH_ROTATE=180`, which draws the splash
   artwork turned 180° (the image files stay right-way-up). The S101AYCR110
   needs it, so `tablet-setup.sh` passes it **by default**; add
   `SPLASH_ROTATE=0` for a tablet whose splash is already correct, and also
   whenever you use `BOOT_ROTATION` (the splash follows that rotation).
   To change it on a unit that's already set up:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/scripts/06_plymouth.sh \
     | sudo SPLASH_ROTATE=180 bash      # or SPLASH_ROTATE=0 to undo
   sudo reboot
   ```

2. **Display is right but touch is mirrored** (touch the top-left corner,
   cursor lands elsewhere)? Reboot after step 1 and re-test first — step 1
   usually fixes touch too. Only if it's still wrong, set the touch matrix:

   | touch top-left, cursor lands… | run |
   | --- | --- |
   | bottom-right | `sudo FLIP=xy bash scripts/touch_fix.sh` |
   | top-right | `sudo FLIP=x bash scripts/touch_fix.sh` |
   | bottom-left | `sudo FLIP=y bash scripts/touch_fix.sh` |
   | rotated 90° | `sudo ROTATE=90 bash scripts/touch_fix.sh` (or `270`) |

   Or bake it into provisioning: `TOUCH_FLIP=x` / `TOUCH_ROTATE=90` on the
   `tablet_tweaks.sh` command line (it's applied after the step-1 cleanup,
   so it sticks). Undo with `FLIP=none`.

3. **Auto-rotation flips the screen the wrong way a few seconds after boot**
   (upside down in every position)? The accelerometer is mounted rotated:
   `sudo MODE=180 bash scripts/rotate_fix.sh` (or `90` / `270`), or
   `ACCEL_FIX=180` on the `tablet_tweaks.sh` command line.

Quick check after a reboot: the Boeing wordmark on the splash reads
left-to-right, the kiosk comes up the same way, and touching each corner of
the screen puts the pointer in that same corner.

### Using a tablet as the IPC

A strong tablet can be the IPC itself. Run the **full** install on exactly
one device (it becomes the system of record — the only one running the door
logger), then apply the tablet tweaks on top:

```bash
URL='https://DASHBOARD_HOST/'   # <-- kiosk target
PLC=SET_PLC_IP_HERE                                         # <-- Modbus PLC
sudo apt update && sudo apt install -y curl && \
curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/setup.sh -o setup.sh && \
chmod +x setup.sh && \
sudo APPLIANCE_URL="$URL" PLC_HOST="$PLC" ./setup.sh && \
curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/scripts/tablet_tweaks.sh | sudo bash && \
sudo reboot
```

Every other tablet gets the viewer profile (`tablet-setup.sh` above). Don't
run the door logger on more than one device: you'd get competing databases,
and WAGO PLCs only allow a few concurrent Modbus TCP connections.

## Scripts

| Script | Purpose |
| --- | --- |
| `00_logging.sh` | Set up run logging |
| `01_system_update.sh` | System update + base build tools |
| `02_node_stack.sh` | Node.js, React/Vite, Node-RED (PM2, port 1880) |
| `03_python_docker.sh` | Python packages + Docker |
| `04_beremiz.sh` | Beremiz soft-PLC (source/package + systemd service) |
| `05_wallpaper.sh` | Client wallpaper |
| `06_plymouth.sh` | Client Plymouth boot splash |
| `07_anydesk_install.sh` | RustDesk remote support (Wayland enabled) |
| `08_kiosk.sh` | Boot into a full-screen Google Chrome kiosk |
| `09_doorlog.sh` | Permanent door-event history logger (PLC → SQLite) |
| `10_disable_updates.sh` | Turn off all automatic updates (appliance mode) |
| `11_vscode.sh` | Visual Studio Code (Microsoft apt repo, `.deb` fallback) for on-device work on the dashboard/scanner code |
| `99_finish.sh` | Version summary |

## Kiosk mode (`08_kiosk.sh`)

Enables GDM auto-login for the GUI user and launches Google Chrome in `--kiosk`
mode on login, inside the existing GNOME/Wayland session.

- **Target URL: required, not hardcoded** — pass `APPLIANCE_URL='http://host:port/path'`
  (or `APPLIANCE_IP=<ip>` for plain `http://<ip>`).
- **No password prompts.** Auto-login is enabled and the GNOME login keyring is
  created blank (Chrome is also launched with `--password-store=basic`), so the
  "unlock your login keyring" dialog never appears.
- **No certificate warning.** Self-signed certificates on the target URL are
  accepted automatically (`--ignore-certificate-errors`) — the browser goes
  straight to the app, no "Your connection is not private" approve screen.
- **CSV / file exports save to `~/kiosk-data`.** A managed browser policy sets
  the download folder and disables the "Save As" dialog, so an export button in
  the web portal writes the file straight to
  `/home/<kiosk-user>/kiosk-data/` on the machine.
- Disables screen blanking, locking, and auto-suspend.
- Hides the mouse pointer when idle and suppresses Chrome's crash-restore prompt.
- Installs Google Chrome automatically (Google's apt repo, with a direct `.deb`
  fallback) if not present.
- **Can't be escaped.** A locked system-wide dconf profile removes every way
  out of the GNOME session under Chrome: Super/overview, Alt+Tab, Alt+F4,
  Ctrl+Alt+T, Alt+F2, the hot corner, workspace switching, log out, lock
  screen, quick settings. `KIOSK_HARDEN=0` skips this for a bench unit.
- **Comes back by itself.** The launcher relaunches Chrome if it ever exits
  or crashes, and if the portal isn't up yet at boot it shows a local
  "Connecting…" page that polls and jumps to the portal the moment it answers
  — no dead error page, no reboot needed.
- **Scanner and camera code in the portal works.** The portal is plain
  `http://`, which Chrome treats as insecure and would silently refuse
  `getUserMedia` (camera barcode/QR scanning), Web Serial and WebHID. The
  managed policy marks the kiosk origin as secure, pre-grants the camera,
  and pre-approves serial ports and HID devices for that origin, so nothing
  ever waits on a permission prompt nobody can click. The kiosk user is added
  to `dialout`/`plugdev` and hidraw devices are opened to `plugdev`, so a
  scanner module on `/dev/ttyUSB*`, `/dev/ttyACM*` or `hidraw*` is readable.
  A scanner in USB keyboard-wedge mode needs nothing extra: its keystrokes
  land in whatever field the dashboard has focused.
- **Maintenance without leaving the lockdown.** Over RustDesk (or a bench
  keyboard), `/opt/kiosk/dev-mode.sh` pauses the kiosk and opens a terminal
  and VS Code; `/opt/kiosk/kiosk-mode.sh` (or a reboot) brings the kiosk back.

Run the kiosk step directly (URL is required — set it in the terminal):

```bash
sudo APPLIANCE_URL='http://host:port/path' bash scripts/08_kiosk.sh
sudo APPLIANCE_URL='...' KIOSK_USER=operator bash scripts/08_kiosk.sh
```

Reboot to enter kiosk mode:

```bash
sudo reboot
```

To change the URL after install, edit `KIOSK_URL` at the top of
`/opt/kiosk/start-kiosk.sh` on the device.

## Door event logger (`09_doorlog.sh`)

The WAGO PLC (address set in the terminal via `PLC_HOST=<ip>`) keeps only the
**last 10 events per door**. This
service polls it over Modbus TCP and appends every new event to a permanent
SQLite database on the IPC — no duplicates (unique `door_id + event_seq`
guard), no loss, resumable across restarts and reboots. Source lives in
[`doorlog/`](doorlog/).

| Path | Purpose |
| --- | --- |
| `/opt/doorlog/` | Code + venv (runs as system user `doorlog`) |
| `/etc/doorlog/config.yaml` | Config: PLC host, poll interval, word order, labels |
| `/var/lib/doorlog/doorlog.db` | The permanent event database (WAL mode) |
| `/var/lib/doorlog/backup/` | Nightly `VACUUM INTO` backups, 30 days kept |
| `/var/log/doorlog/doorlog.log` | Service log (logrotate weekly) |

- Doors 1–25 are labeled `R-01`…`R-25` (Receiving), 26–50 `S-01`…`S-25`
  (Shipping); configurable in `config.yaml`.
- Timestamps come from the PLC (local wall-clock) — the IPC clock never
  touches event time.
- Survives PLC outages: reconnects with capped backoff and catches up from
  whatever is still in the ring.
- **PLC prerequisite:** the Modbus holding-register mirror block (summary +
  per-door event blocks) must be mapped on the PLC by the controls engineer.
  Until then the service idles in retry — installing first is safe.
- **Verify on-site:** trip one door you can physically cycle and confirm the
  stored timestamp matches the HMI clock. If timestamps decode to 1970/2100+,
  flip `word_order_high_first` in the config and restart.

Manage and query:

```bash
systemctl status doorlog
tail -f /var/log/doorlog/doorlog.log

# Full history for door R-08
sqlite3 'file:/var/lib/doorlog/doorlog.db?mode=ro' \
  "SELECT event_ts, event_label FROM door_events WHERE door_id=8 ORDER BY event_seq DESC;"

# All alarms in the last 24 h
sqlite3 'file:/var/lib/doorlog/doorlog.db?mode=ro' \
  "SELECT door_label, event_ts, event_label FROM door_events
   WHERE event_type IN (3,4) AND event_ts_epoch >= strftime('%s','now','-1 day')
   ORDER BY event_ts_epoch DESC;"

# CSV export
sqlite3 -header -csv 'file:/var/lib/doorlog/doorlog.db?mode=ro' \
  "SELECT * FROM door_events ORDER BY event_ts_epoch;" > door-history.csv
```

Test without hardware: `python3 /opt/doorlog/tools/plc_sim.py --port 5020`
starts a simulated PLC (type `push <door> <etype>` on stdin), then point
`plc_host: 127.0.0.1` / `plc_port: 5020` at it.

## No automatic updates (`10_disable_updates.sh`)

The machine is an OT appliance — nothing updates on its own. This step turns
off every automatic update path:

- **apt:** unattended-upgrades disabled, `apt-daily` timers stopped and
  masked, all `APT::Periodic` tasks zeroed.
- **snap:** refreshes held indefinitely (`snap refresh --hold`).
- **GNOME:** Software auto-download/install of updates and update-notifier
  popups off (system-wide dconf), release-upgrade prompts set to `never`.
- **Chrome:** updates via apt on Linux, so with apt automation off it stays
  put. To also block manual upgrades: `sudo apt-mark hold google-chrome-stable`.

Manual updates still work normally during a maintenance window:

```bash
sudo apt update && sudo apt upgrade
```

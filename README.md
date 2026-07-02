# Ubuntu Full Stack Setup

Installs Node.js, React, Node-RED, Python, Docker, and Beremiz on fresh Ubuntu,
applies client branding (wallpaper + Plymouth boot splash), installs RustDesk for
remote support, and boots the machine into a full-screen **kiosk**.

## Install

```bash
sudo apt update && sudo apt install curl
curl -fsSL https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/setup.sh -o setup.sh
chmod +x setup.sh
./setup.sh
```

`setup.sh` fetches every numbered script in `scripts/` and runs them in order.

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
| `99_finish.sh` | Version summary |

## Kiosk mode (`08_kiosk.sh`)

Enables GDM auto-login for the GUI user and launches Google Chrome in `--kiosk`
mode on login, inside the existing GNOME/Wayland session.

- **Default URL:** the appliance UI at `http://192.168.1.17`.
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

Override the target URL or user when running the script directly:

```bash
KIOSK_URL="http://192.168.1.17" ./scripts/08_kiosk.sh
KIOSK_USER="operator"           ./scripts/08_kiosk.sh
```

Reboot to enter kiosk mode:

```bash
sudo reboot
```

To change the URL after install, edit `KIOSK_URL` at the top of
`/opt/kiosk/start-kiosk.sh` on the device.

## Door event logger (`09_doorlog.sh`)

The PLC at `192.168.1.17` keeps only the **last 10 events per door**. This
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

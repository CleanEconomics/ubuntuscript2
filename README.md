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
| `08_kiosk.sh` | Boot into a full-screen Chromium kiosk |
| `99_finish.sh` | Version summary |

## Kiosk mode (`08_kiosk.sh`)

Enables GDM auto-login for the GUI user and launches Chromium in `--kiosk`
mode on login, inside the existing GNOME/Wayland session.

- **Default URL:** the Node-RED dashboard at `http://localhost:1880/ui`
  (falls back to `http://localhost:1880` while the app is still starting).
- Disables screen blanking, locking, and auto-suspend.
- Hides the mouse pointer when idle and suppresses Chromium's crash-restore prompt.
- Installs Chromium automatically (apt wrapper or snap) if not present.

Override the target URL or user when running the script directly:

```bash
KIOSK_URL="http://localhost:1880/ui" ./scripts/08_kiosk.sh
KIOSK_USER="operator"                ./scripts/08_kiosk.sh
```

Reboot to enter kiosk mode:

```bash
sudo reboot
```

To change the URL after install, edit `KIOSK_URL` at the top of
`/opt/kiosk/start-kiosk.sh` on the device.

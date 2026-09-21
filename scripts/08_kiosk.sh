#!/usr/bin/env bash
set -euo pipefail

# 08_kiosk.sh
# ---------------------------------------------------------------------------
# Configure the machine to boot straight into a full-screen Google Chrome kiosk.
# Enables GDM auto-login for the GUI user and, on login, launches Google Chrome
# in --kiosk mode pointed at KIOSK_URL. Designed to run inside the existing GNOME
# (Wayland) session set up by the other scripts in this repo.
#
# The target URL is REQUIRED — there is no hardcoded default. Pass one of:
#   APPLIANCE_URL='https://DASHBOARD_HOST/'  (full URL)
#   APPLIANCE_IP=192.168.1.50                                            (becomes http://<ip>)
#   KIOSK_URL='http://host:port/path'                                    (same as APPLIANCE_URL)
#
# Boot is fully unattended: GDM auto-login plus a blank login keyring, so no
# password prompt ever appears. Self-signed certificates on the target URL are
# accepted automatically (no "Your connection is not private" interstitial).
# Files downloaded from the portal (e.g. CSV exports) are saved silently to
# ~/kiosk-data without a save dialog.
#
#   KIOSK_USER="operator" ./08_kiosk.sh   # override the auto-detected GUI user
# ---------------------------------------------------------------------------

# --- Config (no hardcoded target — must come from the environment) -----------
KIOSK_URL="${KIOSK_URL:-${APPLIANCE_URL:-}}"
if [[ -z "$KIOSK_URL" && -n "${APPLIANCE_IP:-}" ]]; then
  KIOSK_URL="http://$APPLIANCE_IP"
fi
if [[ -z "$KIOSK_URL" ]]; then
  echo "❌ No kiosk target set. Run with one of:" >&2
  echo "   sudo APPLIANCE_URL='http://host:port/path' $0" >&2
  echo "   sudo APPLIANCE_IP=192.168.1.50 $0" >&2
  exit 1
fi
KIOSK_FALLBACK_URL="${KIOSK_FALLBACK_URL:-$KIOSK_URL}"
KIOSK_DIR="/opt/kiosk"
START_SCRIPT="$KIOSK_DIR/start-kiosk.sh"

echo "==============================="
echo " 🖥️  Configuring Google Chrome Kiosk"
echo "==============================="

# --- Auto-elevate to root ---------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "🔐 Elevating to root..."
  exec sudo -E bash "$0" "$@"
fi

# --- Detect the real GUI user (never root) ----------------------------------
# SUDO_USER is the most reliable source (logname often fails in GUI terminals).
KIOSK_USER="${KIOSK_USER:-${SUDO_USER:-$(logname 2>/dev/null || who | awk '{print $1; exit}')}}"
if [[ -z "$KIOSK_USER" || "$KIOSK_USER" == "root" ]]; then
  KIOSK_USER="$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')"
fi
if [[ -z "$KIOSK_USER" ]]; then
  echo "❌ Could not determine a GUI user to run the kiosk as." >&2
  exit 1
fi
USER_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
echo "👤 Kiosk user: $KIOSK_USER ($USER_HOME)"
echo "🌐 Kiosk URL:  $KIOSK_URL"

# --- Install browser + helpers ----------------------------------------------
echo "📦 Installing Google Chrome and helpers..."
apt update -y || true
# unclutter hides the mouse pointer (X11/XWayland); xdotool is handy for touch
apt install -y unclutter xdotool curl gnupg ca-certificates || true

# Install Google Chrome (stable). Prefer Google's signed apt repo so Chrome
# stays auto-updated; fall back to the direct .deb if the repo route fails.
install_google_chrome() {
  install -d -m 0755 /etc/apt/keyrings
  if curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
       | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg 2>/dev/null; then
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list
    apt update -y || true
    apt install -y google-chrome-stable && return 0
  fi
  echo "⬇️  Repo install failed — trying direct .deb download..."
  local deb="/tmp/google-chrome-stable_current_amd64.deb"
  if curl -fsSL -o "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
    apt install -y "$deb" || { dpkg -i "$deb" || true; apt -f install -y || true; }
    rm -f "$deb"
    command -v google-chrome-stable >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Locate/install the browser: Google Chrome first (what we want everywhere).
BROWSER_BIN=""
if command -v google-chrome-stable >/dev/null 2>&1; then
  BROWSER_BIN="$(command -v google-chrome-stable)"
elif command -v google-chrome >/dev/null 2>&1; then
  BROWSER_BIN="$(command -v google-chrome)"
else
  echo "⬇️  Installing Google Chrome..."
  if install_google_chrome; then
    BROWSER_BIN="$(command -v google-chrome-stable || command -v google-chrome || true)"
  fi
fi

# Last-resort fallback so the kiosk still comes up where Google Chrome isn't
# available (e.g. non-amd64/ARM boxes). Chrome is strongly preferred.
if [[ -z "$BROWSER_BIN" ]]; then
  echo "⚠️  Google Chrome unavailable — falling back to Chromium." >&2
  if command -v chromium-browser >/dev/null 2>&1; then
    BROWSER_BIN="$(command -v chromium-browser)"
  elif command -v chromium >/dev/null 2>&1; then
    BROWSER_BIN="$(command -v chromium)"
  elif apt install -y chromium-browser 2>/dev/null; then
    BROWSER_BIN="$(command -v chromium-browser || true)"
  elif command -v snap >/dev/null 2>&1; then
    snap install chromium || true
    BROWSER_BIN="$(command -v chromium || true)"
  fi
fi

BROWSER_BIN="${BROWSER_BIN:-google-chrome-stable}"
echo "🌐 Using browser: $BROWSER_BIN"

# --- Managed policy: silent CSV downloads + no HTTPS-First warning ----------
# PromptForDownloadLocation=false kills the "Save As" dialog, so an export
# button in the web portal writes straight to disk.
# HttpsOnlyMode/HttpsUpgradesEnabled/HttpAllowlist stop Chrome's "this site
# doesn't support a secure connection" interstitial that HTTPS-First mode
# shows for plain-HTTP sites in Incognito. Policy dirs cover Chrome and both
# Chromium (deb/snap) layouts.
KIOSK_HOST="$(echo "$KIOSK_URL" | sed -E 's|^[a-zA-Z]+://||; s|[/:].*$||')"
# Origin = scheme://host[:port] — what Chrome keys camera + secure-context
# policies on. Plain http:// is NOT a secure context, so getUserMedia (the
# portal's camera barcode/QR scanner), Web Serial and WebHID would all
# silently fail without OverrideSecurityRestrictionsOnInsecureOrigin.
# VideoCaptureAllowedUrls grants the camera with no "Allow?" prompt, and
# Serial/WebHid*AllowAll* skip the device-chooser dialog, so dashboard code
# that talks to a scanner module directly just works (nobody can click a
# prompt on a kiosk). A scanner in USB keyboard-wedge mode needs nothing:
# its keystrokes land in whatever field the portal has focused.
# The kiosk user also joins dialout/plugdev below so serial ports are readable.
KIOSK_ORIGIN="$(echo "$KIOSK_URL" | sed -E 's|^([a-zA-Z]+://[^/]+).*$|\1|')"
echo "📁 Configuring browser policy (downloads -> ~/kiosk-data, plain HTTP + camera allowed for $KIOSK_ORIGIN)..."
for PDIR in /etc/opt/chrome/policies/managed \
            /etc/chromium/policies/managed \
            /etc/chromium-browser/policies/managed; do
  mkdir -p "$PDIR"
  cat > "$PDIR/kiosk-downloads.json" <<EOF
{
  "DownloadDirectory": "\${user_home}/kiosk-data",
  "PromptForDownloadLocation": false,
  "DefaultBrowserSettingEnabled": false,
  "HttpsOnlyMode": "disallowed",
  "HttpsUpgradesEnabled": false,
  "HttpAllowlist": ["$KIOSK_HOST"],

  "OverrideSecurityRestrictionsOnInsecureOrigin": ["$KIOSK_ORIGIN"],
  "VideoCaptureAllowedUrls": ["$KIOSK_ORIGIN"],
  "AudioCaptureAllowedUrls": ["$KIOSK_ORIGIN"],
  "SerialAllowAllPortsForUrls": ["$KIOSK_ORIGIN"],
  "WebHidAllowAllDevicesForUrls": ["$KIOSK_ORIGIN"],
  "DefaultNotificationsSetting": 2,
  "DefaultGeolocationSetting": 2,

  "DeveloperToolsAvailability": 2,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "TranslateEnabled": false,
  "BackgroundModeEnabled": false,
  "MetricsReportingEnabled": false,
  "ShowHomeButton": false,
  "BookmarkBarEnabled": false,
  "SavingBrowserHistoryDisabled": true
}
EOF
done
sudo -u "$KIOSK_USER" mkdir -p "$USER_HOME/kiosk-data"

# Serial/USB scanner modules show up as /dev/ttyUSB*, /dev/ttyACM* or
# hidraw*; the kiosk user needs group membership to open them from Chrome.
for grp in dialout plugdev; do
  getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "$KIOSK_USER" || true
done
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/70-kiosk-scanner.rules <<'EOF'
# Written by 08_kiosk.sh — let the kiosk user open USB HID scanner modules via WebHID.
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0660", GROUP="plugdev"
EOF
udevadm control --reload-rules 2>/dev/null || true

# --- Enable GDM auto-login for the kiosk user -------------------------------
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]]; then
  echo "🔧 Enabling auto-login for $KIOSK_USER in $GDM_CONF..."
  grep -q '^\[daemon\]' "$GDM_CONF" || printf '\n[daemon]\n' >> "$GDM_CONF"
  # Drop any prior autologin lines, then insert fresh ones under [daemon]
  sed -i '/^AutomaticLoginEnable/d; /^AutomaticLogin=/d' "$GDM_CONF"
  sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$KIOSK_USER" "$GDM_CONF"
  echo "✅ Auto-login enabled."
else
  echo "⚠️  $GDM_CONF not found — is GNOME/GDM installed? Auto-login not configured."
fi

# --- Kill the keyring password prompt ----------------------------------------
# Auto-login never types a password, so the GNOME login keyring stays locked
# and the first app to touch it (Chrome) pops an "unlock your login keyring"
# password dialog. Two-part fix: give the kiosk user a blank (plaintext) login
# keyring if none exists, and launch Chrome with --password-store=basic so it
# never touches the keyring at all.
KEYRING_DIR="$USER_HOME/.local/share/keyrings"
if [[ ! -f "$KEYRING_DIR/login.keyring" ]]; then
  echo "🔓 Creating blank login keyring (no unlock prompt on boot)..."
  sudo -u "$KIOSK_USER" mkdir -p "$KEYRING_DIR"
  cat > "$KEYRING_DIR/login.keyring" <<'EOF'
[keyring]
display-name=login
ctime=0
mtime=0
lock-on-idle=false
lock-after=false
EOF
  printf 'login' > "$KEYRING_DIR/default"
  chown "$KIOSK_USER":"$KIOSK_USER" "$KEYRING_DIR/login.keyring" "$KEYRING_DIR/default"
  chmod 700 "$KEYRING_DIR"
  chmod 600 "$KEYRING_DIR/login.keyring"
else
  echo "ℹ️  Existing login keyring found — leaving it alone (Chrome bypasses it anyway)."
fi

# --- Lock the GNOME session so the kiosk can't be escaped -------------------
# Chrome --kiosk only makes Chrome full-screen; GNOME Shell underneath still
# answers Super, Alt+Tab, Alt+F4, Ctrl+Alt+T, the hot corner, the overview and
# workspace gestures. These system-wide dconf settings + locks close every one
# of those exits. KIOSK_HARDEN=0 skips this (e.g. a bench unit you want to
# poke at). Remote support stays possible via RustDesk; a physical keyboard
# can still reach a text console with Ctrl+Alt+F3.
if [[ "${KIOSK_HARDEN:-1}" == "1" ]]; then
  echo "🔒 Locking down the GNOME session (no overview, no Alt+Tab, no terminal hotkey, no hot corner)..."
  apt install -y dconf-cli >/dev/null 2>&1 || true
  mkdir -p /etc/dconf/profile /etc/dconf/db/local.d/locks
  if [[ ! -f /etc/dconf/profile/user ]]; then
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
  elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
    echo 'system-db:local' >> /etc/dconf/profile/user
  fi
  cat > /etc/dconf/db/local.d/02-kiosk-lockdown <<'EOF'
[org/gnome/desktop/lockdown]
disable-command-line=true
disable-log-out=true
disable-user-switching=true
disable-lock-screen=true
disable-application-handlers=true
disable-printing=true
disable-print-setup=true
disable-save-to-disk=false

[org/gnome/desktop/interface]
enable-hot-corners=false

[org/gnome/mutter]
overlay-key=''
dynamic-workspaces=false
edge-tiling=false

[org/gnome/desktop/wm/preferences]
num-workspaces=1

[org/gnome/shell/keybindings]
toggle-overview=@as []
toggle-application-view=@as []
toggle-message-tray=@as []
toggle-quick-settings=@as []
focus-active-notification=@as []
open-new-window-application-1=@as []
switch-to-application-1=@as []
switch-to-application-2=@as []
switch-to-application-3=@as []
switch-to-application-4=@as []
switch-to-application-5=@as []
switch-to-application-6=@as []
switch-to-application-7=@as []
switch-to-application-8=@as []
switch-to-application-9=@as []
screenshot=@as []
screenshot-window=@as []
show-screenshot-ui=@as []
show-screen-recording-ui=@as []

[org/gnome/desktop/wm/keybindings]
close=@as []
minimize=@as []
maximize=@as []
unmaximize=@as []
toggle-maximized=@as []
toggle-fullscreen=@as []
begin-move=@as []
begin-resize=@as []
switch-applications=@as []
switch-applications-backward=@as []
switch-windows=@as []
switch-windows-backward=@as []
switch-group=@as []
switch-group-backward=@as []
switch-panels=@as []
switch-panels-backward=@as []
cycle-windows=@as []
cycle-windows-backward=@as []
cycle-panels=@as []
cycle-panels-backward=@as []
cycle-group=@as []
cycle-group-backward=@as []
panel-run-dialog=@as []
panel-main-menu=@as []
activate-window-menu=@as []
show-desktop=@as []
switch-to-workspace-1=@as []
switch-to-workspace-left=@as []
switch-to-workspace-right=@as []
switch-to-workspace-up=@as []
switch-to-workspace-down=@as []
switch-to-workspace-last=@as []
move-to-workspace-left=@as []
move-to-workspace-right=@as []
move-to-workspace-up=@as []
move-to-workspace-down=@as []
move-to-monitor-left=@as []
move-to-monitor-right=@as []
move-to-monitor-up=@as []
move-to-monitor-down=@as []

[org/gnome/settings-daemon/plugins/media-keys]
terminal=@as []
logout=@as []
screensaver=@as []
home=@as []
control-center=@as []
search=@as []
www=@as []
email=@as []
calculator=@as []
help=@as []
screenshot=@as []
window-screenshot=@as []
area-screenshot=@as []
screencast=@as []
EOF
  cat > /etc/dconf/db/local.d/locks/02-kiosk-lockdown <<'EOF'
/org/gnome/desktop/lockdown/disable-log-out
/org/gnome/desktop/lockdown/disable-user-switching
/org/gnome/desktop/lockdown/disable-lock-screen
/org/gnome/desktop/interface/enable-hot-corners
/org/gnome/mutter/overlay-key
/org/gnome/mutter/dynamic-workspaces
/org/gnome/desktop/wm/preferences/num-workspaces
/org/gnome/shell/keybindings/toggle-overview
/org/gnome/shell/keybindings/toggle-application-view
/org/gnome/shell/keybindings/toggle-quick-settings
/org/gnome/desktop/wm/keybindings/close
/org/gnome/desktop/wm/keybindings/switch-applications
/org/gnome/desktop/wm/keybindings/switch-windows
/org/gnome/desktop/wm/keybindings/panel-run-dialog
/org/gnome/settings-daemon/plugins/media-keys/terminal
/org/gnome/settings-daemon/plugins/media-keys/logout
EOF
  dconf update || echo "⚠️  dconf update failed — lockdown will apply after next 'sudo dconf update'"
  echo "✅ GNOME session locked (KIOSK_HARDEN=0 to skip)."
else
  echo "ℹ️  KIOSK_HARDEN=0 — GNOME session left open (escapable kiosk)."
fi

# --- Write the kiosk launcher ----------------------------------------------
echo "🚀 Writing kiosk launcher to $START_SCRIPT..."
mkdir -p "$KIOSK_DIR"
cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
# Auto-generated by 08_kiosk.sh — launches Google Chrome in kiosk mode.
set -u

URL="\${KIOSK_URL:-$KIOSK_URL}"
FALLBACK="\${KIOSK_FALLBACK_URL:-$KIOSK_FALLBACK_URL}"
BROWSER="$BROWSER_BIN"
PROFILE="\$HOME/.config/kiosk-chrome"

# CSV exports / downloads from the portal land here (managed policy points
# Chrome at this folder with no save dialog).
mkdir -p "\$HOME/kiosk-data"

# --- Keep the screen awake (GNOME) ---
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.session idle-delay 0 || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false || true
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' || true
fi

# --- Keep the screen awake (Xorg / XWayland) ---
if command -v xset >/dev/null 2>&1 && [ -n "\${DISPLAY:-}" ]; then
  xset s off || true
  xset s noblank || true
  xset -dpms || true
fi

# --- Hide the mouse pointer when idle (X11/XWayland) ---
if command -v unclutter >/dev/null 2>&1; then
  unclutter -idle 0.5 -root &
fi

# --- Suppress "Google Chrome didn't shut down correctly" restore prompt ---
PREF="\$PROFILE/Default/Preferences"
if [ -f "\$PREF" ]; then
  sed -i 's/"exit_type":"[^"]\+"/"exit_type":"Normal"/' "\$PREF" || true
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "\$PREF" || true
fi

# --- Wait for the target URL, fall back if the app isn't up yet ---
# -k: accept self-signed certs so the readiness check matches the browser.
# If neither URL answers within ~60 s, open the local "connecting" page
# instead: it keeps polling and jumps to the portal the moment it's up, so
# the kiosk never parks on a dead Chrome error page.
TARGET=""
for _ in \$(seq 1 30); do
  if curl -fsSk --max-time 2 "\$URL" >/dev/null 2>&1; then TARGET="\$URL"; break; fi
  if curl -fsSk --max-time 2 "\$FALLBACK" >/dev/null 2>&1; then TARGET="\$FALLBACK"; break; fi
  sleep 2
done
if [ -z "\$TARGET" ]; then
  TARGET="file://$KIOSK_DIR/connecting.html"
fi

# --- Prefer native Wayland when the session is Wayland ---
# The IME flags make Chrome tell GNOME when a text field has focus, which is
# what pops the on-screen touch keyboard on tablets.
OZONE=""
if [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  OZONE="--ozone-platform=wayland --enable-features=UseOzonePlatform --enable-wayland-ime --wayland-text-input-version=3"
fi

# --password-store=basic      : never touch the GNOME keyring (no password prompt)
# --ignore-certificate-errors : accept the appliance's self-signed cert (no
#                               "Your connection is not private" interstitial)
# --test-type                 : suppress the warning bar those flags would show
# --autoplay-policy=...       : let the dashboard's station buzzer (Web Audio)
#                               sound without waiting for a first tap, so an
#                               alert is audible even right after a reboot
#
# Relaunch loop: if Chrome crashes, is killed, or somehow gets closed, the
# kiosk comes straight back instead of leaving a bare desktop until reboot.
while true; do
  "\$BROWSER" \\
    --user-data-dir="\$PROFILE" \\
    --kiosk "\$TARGET" \\
    --start-fullscreen \\
    --noerrdialogs \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --disable-features=TranslateUI \\
    --no-first-run \\
    --disable-pinch \\
    --overscroll-history-navigation=0 \\
    --password-store=basic \\
    --ignore-certificate-errors \\
    --autoplay-policy=no-user-gesture-required \\
    --test-type \\
    --incognito \\
    \$OZONE
  # Chrome exited. If the portal is up now, go straight to it on relaunch.
  if curl -fsSk --max-time 2 "\$URL" >/dev/null 2>&1; then TARGET="\$URL"; fi
  sleep 2
done
EOF
chmod +x "$START_SCRIPT"

# --- Local "connecting" page shown until the portal answers ------------------
# Polls the portal with a no-cors fetch (opaque response = reachable) and
# replaces itself with the portal the moment it's up. No user action needed.
cat > "$KIOSK_DIR/connecting.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Connecting</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html,body{height:100%;margin:0;background:#ffffff;color:#1f2937;font:20px/1.5 system-ui,sans-serif}
  body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:24px}
  img{width:min(40vw,320px);height:auto}
  .spin{width:56px;height:56px;border:6px solid #dbe3ee;border-top-color:#0033a0;border-radius:50%;animation:s 1s linear infinite}
  @keyframes s{to{transform:rotate(360deg)}}
  small{color:#6b7280;font-size:14px}
</style></head>
<body>
  <!-- client logo installed by 06_plymouth.sh; hidden if that step was skipped -->
  <img src="file:///usr/share/plymouth/themes/client-brand/logo.png" alt="" onerror="this.style.display='none'">
  <div class="spin"></div>
  <div>Connecting to the portal…</div>
  <small id="s">$KIOSK_URL</small>
  <script>
    var URL_="$KIOSK_URL", FB_="$KIOSK_FALLBACK_URL", n=0;
    function go(u){ location.replace(u); }
    function probe(u){ return fetch(u,{mode:"no-cors",cache:"no-store"}).then(function(){return true;},function(){return false;}); }
    function tick(){
      n++; document.getElementById("s").textContent = URL_ + "  (attempt " + n + ")";
      probe(URL_).then(function(ok){ if(ok){go(URL_);return;} return probe(FB_).then(function(ok2){ if(ok2) go(FB_); }); });
    }
    tick(); setInterval(tick, 5000);
  </script>
</body></html>
EOF
chown -R "$KIOSK_USER":"$KIOSK_USER" "$KIOSK_DIR"

# --- Tech helpers: pause the kiosk for maintenance, resume it after ----------
# Meant to be run from a RustDesk session (or a bench keyboard). dev-mode
# stops the relaunch loop + Chrome and opens a terminal and VS Code (if
# installed by 11_vscode.sh). kiosk-mode brings the kiosk back without a
# reboot. Both run as the kiosk user; the GNOME lockdown stays in place.
cat > "$KIOSK_DIR/dev-mode.sh" <<'EOF'
#!/usr/bin/env bash
# Pause the kiosk for maintenance: stop the relaunch loop + Chrome, open tools.
pkill -f /opt/kiosk/start-kiosk.sh 2>/dev/null || true
pkill -f -- '--user-data-dir=.*kiosk-chrome' 2>/dev/null || true
sleep 1
# The kiosk lockdown blocks terminal launching; lift just that for the tech.
gsettings set org.gnome.desktop.lockdown disable-command-line false 2>/dev/null || true
command -v gnome-terminal >/dev/null 2>&1 && (gnome-terminal >/dev/null 2>&1 &)
command -v code >/dev/null 2>&1 && (code "$HOME" >/dev/null 2>&1 &)
echo "Kiosk paused. Run /opt/kiosk/kiosk-mode.sh (or reboot) to resume."
EOF
cat > "$KIOSK_DIR/kiosk-mode.sh" <<'EOF'
#!/usr/bin/env bash
# Resume the kiosk without rebooting.
pkill -f /opt/kiosk/start-kiosk.sh 2>/dev/null || true
pkill -f -- '--user-data-dir=.*kiosk-chrome' 2>/dev/null || true
sleep 1
gsettings reset org.gnome.desktop.lockdown disable-command-line 2>/dev/null || true
setsid nohup /opt/kiosk/start-kiosk.sh >/dev/null 2>&1 &
echo "Kiosk resumed."
EOF
chmod +x "$KIOSK_DIR/dev-mode.sh" "$KIOSK_DIR/kiosk-mode.sh"
chown -R "$KIOSK_USER":"$KIOSK_USER" "$KIOSK_DIR"

# --- Autostart entry (runs inside the user's GNOME session) -----------------
AUTOSTART_DIR="$USER_HOME/.config/autostart"
echo "🧩 Creating autostart entry..."
sudo -u "$KIOSK_USER" mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kiosk Browser
Comment=Launch Google Chrome in full-screen kiosk mode
Exec=$START_SCRIPT
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
NoDisplay=false
EOF
chown -R "$KIOSK_USER":"$KIOSK_USER" "$AUTOSTART_DIR"

echo ""
echo "==============================="
echo "✅ Kiosk configured!"
echo "   User:     $KIOSK_USER (auto-login)"
echo "   URL:      $KIOSK_URL"
echo "   Launcher: $START_SCRIPT"
echo "   Reboot to enter kiosk mode:  sudo reboot"
echo "==============================="

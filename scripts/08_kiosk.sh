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
#   APPLIANCE_URL='http://74.208.61.41:3005/login?callbackUrl=%2Fadmin'  (full URL)
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
echo "📁 Configuring browser policy (downloads -> ~/kiosk-data, plain HTTP allowed for $KIOSK_HOST)..."
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
  "HttpAllowlist": ["$KIOSK_HOST"]
}
EOF
done
sudo -u "$KIOSK_USER" mkdir -p "$USER_HOME/kiosk-data"

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
TARGET="\$URL"
for _ in \$(seq 1 30); do
  if curl -fsSk --max-time 2 "\$URL" >/dev/null 2>&1; then TARGET="\$URL"; break; fi
  if curl -fsSk --max-time 2 "\$FALLBACK" >/dev/null 2>&1; then TARGET="\$FALLBACK"; fi
  sleep 2
done

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
exec "\$BROWSER" \\
  --user-data-dir="\$PROFILE" \\
  --kiosk "\$TARGET" \\
  --start-fullscreen \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-features=TranslateUI \\
  --no-first-run \\
  --fast --fast-start \\
  --disable-pinch \\
  --overscroll-history-navigation=0 \\
  --check-for-update-interval=31536000 \\
  --password-store=basic \\
  --ignore-certificate-errors \\
  --test-type \\
  --incognito \\
  \$OZONE
EOF
chmod +x "$START_SCRIPT"
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

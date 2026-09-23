#!/usr/bin/env bash
# 06_plymouth.sh — client-branded Plymouth boot splash.
# All theme assets are downloaded to a staging dir first; the theme is only
# installed and activated if every file arrived, so a flaky network can't
# leave the machine pointing at a half-installed splash.
echo "🎨 Installing Plymouth theme..."
export DEBIAN_FRONTEND=noninteractive
sudo -E apt install -y plymouth plymouth-themes

THEME_NAME="client-brand"
THEME_DIR="/usr/share/plymouth/themes/$THEME_NAME"
THEME_REPO_URL="https://raw.githubusercontent.com/CleanEconomics/ubuntuscript2/main/client-brand"
STAGE="$(mktemp -d)"

ok=1
for f in "$THEME_NAME.plymouth" "$THEME_NAME.script" logo.png background.png spinner.png; do
  if ! curl -fsSL "$THEME_REPO_URL/$f" -o "$STAGE/$f"; then
    echo "⚠️  Failed to download $f"
    ok=0
  fi
done

if [[ $ok -ne 1 ]]; then
  echo "⚠️  Theme assets incomplete — leaving the current boot splash untouched."
  rm -rf "$STAGE"
  exit 1
fi

# SPLASH_ROTATE=180 turns the splash artwork upside down, for panels whose
# boot screen comes up inverted while the desktop is fine (the S101AYCR110).
# It only affects the splash; tablet-setup.sh passes it by default.
case "${SPLASH_ROTATE:-0}" in
  180)
    sed -i 's/^flip = 0;$/flip = 1;/' "$STAGE/$THEME_NAME.script"
    if grep -qx 'flip = 1;' "$STAGE/$THEME_NAME.script"; then
      echo "🔄 Splash drawn rotated 180 degrees (SPLASH_ROTATE=180)"
    else
      echo "⚠️  Could not set the splash rotation — splash left unrotated."
    fi
    ;;
  0) ;;
  *) echo "⚠️  SPLASH_ROTATE must be 0 or 180 — splash left unrotated." ;;
esac

sudo mkdir -p "$THEME_DIR"
sudo cp "$STAGE"/* "$THEME_DIR"/
rm -rf "$STAGE"

# Priority 200 beats Ubuntu's default bgrt theme (110) — bgrt is the one that
# shows the factory/vendor logo at boot. --set pins ours regardless.
sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$THEME_DIR/$THEME_NAME.plymouth" 200
sudo update-alternatives --set default.plymouth "$THEME_DIR/$THEME_NAME.plymouth"
sudo update-initramfs -u
echo "✅ Boot splash set to $THEME_NAME"

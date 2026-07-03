#!/usr/bin/env bash
# Hyphen-free alias for tablet-setup.sh.
# Exists because messaging/notes apps convert hyphens to en-dashes, which
# breaks hand-relayed commands; this filename survives that. Same usage:
#   sudo APPLIANCE_URL='http://host:port/path' bash tablet.sh
#   sudo APPLIANCE_IP=192.168.1.50 bash tablet.sh
set -e
REPO="CleanEconomics/ubuntuscript2"
BRANCH="main"
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/tablet-setup.sh" -o /tmp/tablet-setup.sh
exec bash /tmp/tablet-setup.sh "$@"

#!/usr/bin/env bash
# 01_system_update.sh — system update + base build tools.
# Fully non-interactive: no dpkg "keep your config?" prompts and no
# needrestart "restart services?" dialog can stall an unattended provision.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "📦 Updating system packages..."
sudo -E apt update -y
sudo -E apt upgrade "${APT_OPTS[@]}"
sudo -E apt install "${APT_OPTS[@]}" build-essential curl wget git unzip

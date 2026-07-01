#!/usr/bin/env bash
echo "📦 Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y build-essential curl wget git unzip

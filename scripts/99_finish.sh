#!/usr/bin/env bash
echo "✅ Installation complete!"
node -v
npm -v
python3 --version
docker --version
docker compose version || true
echo "Node-RED running via PM2 (port 1880)"
echo "Setup finished successfully at $(date)"

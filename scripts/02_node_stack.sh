#!/usr/bin/env bash
echo "🟢 Installing Node.js + React + Node-RED..."

# Node.js & npm
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g n
sudo n lts
hash -r

# React
sudo npm install -g create-react-app vite

# Node-RED
sudo npm install -g --unsafe-perm node-red pm2
pm2 start $(which node-red) --name node-red
pm2 startup systemd -u $USER --hp $HOME
pm2 save


sudo env PATH=$PATH:/usr/local/bin pm2 startup systemd -u bsy --hp /home/bsy

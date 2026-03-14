#!/bin/bash
# ============================================================
# EduStack — Memcached Provisioning Script
# VM: mc01 | IP: 192.168.56.14
# Purpose: Caches student profile and course data to reduce
#          MySQL queries. Speeds up repeated page loads.
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

set -euo pipefail

echo ">>> [mc01] Updating OS packages..."
sudo dnf update -y
sudo dnf install -y epel-release
sudo dnf install -y memcached

echo ">>> [mc01] Starting Memcached service..."
sudo systemctl start memcached
sudo systemctl enable memcached

echo ">>> [mc01] Configuring Memcached to listen on all interfaces..."
# By default memcached binds to 127.0.0.1 — we need 0.0.0.0 for app01 to reach it
sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/sysconfig/memcached
sudo systemctl restart memcached

echo ">>> [mc01] Opening firewall ports for Memcached..."
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo firewall-cmd --add-port=11211/tcp --permanent
sudo firewall-cmd --add-port=11111/udp --permanent
sudo firewall-cmd --reload

echo ">>> [mc01] Verifying Memcached is listening on port 11211..."
sudo memcached -p 11211 -U 11111 -u memcached -d || true

echo ">>> [mc01] Memcached provisioning complete."
sudo systemctl status memcached --no-pager

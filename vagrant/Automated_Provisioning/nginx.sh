#!/bin/bash
# ============================================================
# EduStack — Nginx Provisioning Script
# VM: web01 (Ubuntu) | IP: 192.168.56.11
# Purpose: Reverse proxy — receives all student browser
#          requests on port 80, forwards to Tomcat on :8080
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

set -euo pipefail

echo ">>> [web01] Updating Ubuntu packages..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y nginx

echo ">>> [web01] Writing Nginx reverse proxy configuration..."
sudo tee /etc/nginx/sites-available/edustack > /dev/null <<'NGINX'
upstream eduapp {
    server app01:8080;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://eduapp;
        proxy_set_header   Host             $host;
        proxy_set_header   X-Real-IP        $remote_addr;
        proxy_set_header   X-Forwarded-For  $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout    60s;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "EduStack healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX

echo ">>> [web01] Enabling EduStack site and removing default..."
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/edustack /etc/nginx/sites-enabled/edustack

echo ">>> [web01] Testing and restarting Nginx..."
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

echo ">>> [web01] Nginx provisioning complete."
sudo systemctl status nginx --no-pager
echo "EduStack is accessible at: http://192.168.56.11"

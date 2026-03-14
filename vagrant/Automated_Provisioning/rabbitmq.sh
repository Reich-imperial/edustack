#!/bin/bash
# ============================================================
# EduStack — RabbitMQ Provisioning Script
# VM: rmq01 | IP: 192.168.56.16
# Purpose: Message broker for async notifications —
#          grade updates, announcement emails, event alerts
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

set -euo pipefail

echo ">>> [rmq01] Updating OS packages..."
sudo dnf update -y
sudo dnf install -y epel-release

echo ">>> [rmq01] Installing RabbitMQ..."
sudo dnf -y install centos-release-rabbitmq-38
sudo dnf --enablerepo=centos-rabbitmq-38 -y install rabbitmq-server

echo ">>> [rmq01] Starting RabbitMQ service..."
sudo systemctl enable --now rabbitmq-server
sudo systemctl start rabbitmq-server

echo ">>> [rmq01] Configuring RabbitMQ (disable loopback restriction)..."
sudo sh -c 'echo "[{rabbit, [{loopback_users, []}]}]." > /etc/rabbitmq/rabbitmq.config'

echo ">>> [rmq01] Creating EduStack RabbitMQ user..."
sudo rabbitmqctl add_user edustack edustack@2026 || true
sudo rabbitmqctl set_user_tags edustack administrator
sudo rabbitmqctl set_permissions -p / edustack ".*" ".*" ".*"

sudo systemctl restart rabbitmq-server

echo ">>> [rmq01] Opening firewall port 5672 for AMQP..."
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo firewall-cmd --add-port=5672/tcp  --permanent
sudo firewall-cmd --add-port=15672/tcp --permanent  # management console
sudo firewall-cmd --reload

echo ">>> [rmq01] RabbitMQ provisioning complete."
sudo systemctl status rabbitmq-server --no-pager

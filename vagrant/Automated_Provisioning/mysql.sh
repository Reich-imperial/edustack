#!/bin/bash
# ============================================================
# EduStack — MySQL / MariaDB Provisioning Script
# VM: db01 | IP: 192.168.56.15
# Purpose: Stores all student portal data (users, courses,
#          grades, announcements)
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

set -euo pipefail

DATABASE_PASS='eduAdmin@2026'

echo ">>> [db01] Updating OS packages..."
sudo dnf update -y
sudo dnf install -y epel-release
sudo dnf install -y git mariadb-server

echo ">>> [db01] Starting MariaDB service..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

echo ">>> [db01] Securing MariaDB installation..."
sudo mysqladmin -u root password "$DATABASE_PASS"
sudo mysql -u root -p"$DATABASE_PASS" -e "DELETE FROM mysql.user WHERE User='';"
sudo mysql -u root -p"$DATABASE_PASS" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
sudo mysql -u root -p"$DATABASE_PASS" -e "DROP DATABASE IF EXISTS test;"
sudo mysql -u root -p"$DATABASE_PASS" -e "FLUSH PRIVILEGES;"

echo ">>> [db01] Creating EduStack database and user..."
sudo mysql -u root -p"$DATABASE_PASS" -e "CREATE DATABASE IF NOT EXISTS edustack;"
sudo mysql -u root -p"$DATABASE_PASS" -e "GRANT ALL PRIVILEGES ON edustack.* TO 'eduadmin'@'app01' IDENTIFIED BY 'eduAdmin@2026';"
sudo mysql -u root -p"$DATABASE_PASS" -e "FLUSH PRIVILEGES;"

echo ">>> [db01] Loading EduStack schema and seed data..."
sudo git clone -b main https://github.com/Reich-imperial/edustack.git /tmp/edustack
sudo mysql -u root -p"$DATABASE_PASS" edustack < /tmp/edustack/src/main/resources/db_backup.sql

echo ">>> [db01] Opening firewall for MySQL port 3306..."
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo firewall-cmd --add-port=3306/tcp --permanent
sudo firewall-cmd --reload

echo ">>> [db01] MariaDB provisioning complete."
sudo systemctl status mariadb --no-pager

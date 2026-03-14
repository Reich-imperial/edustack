#!/bin/bash
# ============================================================
# EduStack — Apache Tomcat Provisioning Script
# VM: app01 | IP: 192.168.56.12
# Purpose: Runs the EduStack Java web application (.war)
#          Connects to MySQL, Memcached, and RabbitMQ
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

set -euo pipefail

TOMCAT_VERSION="10.1.26"
TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"

echo ">>> [app01] Updating OS and installing dependencies..."
sudo dnf update -y
sudo dnf install -y java-17-openjdk java-17-openjdk-devel git wget maven

echo ">>> [app01] Creating tomcat system user..."
sudo useradd --home-dir /usr/local/tomcat --shell /sbin/nologin tomcat || true

echo ">>> [app01] Downloading and installing Tomcat ${TOMCAT_VERSION}..."
cd /tmp
wget -q "$TOMCAT_URL"
tar xzvf "apache-tomcat-${TOMCAT_VERSION}.tar.gz"
sudo cp -r "apache-tomcat-${TOMCAT_VERSION}/"* /usr/local/tomcat/
sudo chown -R tomcat:tomcat /usr/local/tomcat

echo ">>> [app01] Creating Tomcat systemd service..."
sudo tee /etc/systemd/system/tomcat.service > /dev/null <<'SERVICE'
[Unit]
Description=EduStack — Apache Tomcat Web Application Container
After=network.target

[Service]
User=tomcat
Group=tomcat
WorkingDirectory=/usr/local/tomcat
Environment=JAVA_HOME=/usr/lib/jvm/jre
Environment=CATALINA_HOME=/usr/local/tomcat
ExecStart=/usr/local/tomcat/bin/catalina.sh run
ExecStop=/usr/local/tomcat/bin/shutdown.sh
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat

echo ">>> [app01] Cloning EduStack source code..."
git clone -b main https://github.com/Reich-imperial/edustack.git /tmp/edustack
cd /tmp/edustack

echo ">>> [app01] Building EduStack artifact with Maven..."
mvn install

echo ">>> [app01] Deploying EduStack.war to Tomcat..."
sudo systemctl stop tomcat
sudo rm -rf /usr/local/tomcat/webapps/ROOT*
sudo cp target/EduStack.war /usr/local/tomcat/webapps/ROOT.war
sudo chown tomcat:tomcat /usr/local/tomcat/webapps/ROOT.war
sudo systemctl start tomcat

echo ">>> [app01] Opening firewall port 8080..."
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --reload

echo ">>> [app01] Tomcat provisioning complete."
sudo systemctl status tomcat --no-pager

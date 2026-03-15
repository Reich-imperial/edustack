#!/bin/bash
# ============================================================
# EduStack — Full Stack Health Check Script
# Checks all 5 VMs are running and services are healthy
# Usage: bash scripts/health-check.sh
# Run from: vagrant/Automated_Provisioning folder
# Author: Samson Olanipekun (github.com/Reich-imperial)
# ============================================================

VAGRANT_DIR="/c/Users/Helix/OneDrive/Desktop/edustack-vagrant/Automated_Provisioning"

echo "================================================"
echo " EduStack — Full Stack Health Check"
echo " $(date)"
echo "================================================"
echo ""

cd "$VAGRANT_DIR"

check_service() {
    local VM=$1
    local SERVICE=$2
    local PORT=$3

    echo "--- $VM ---"
    STATUS=$(vagrant ssh $VM -c "sudo systemctl is-active $SERVICE 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ "$STATUS" = "active" ]; then
        echo "  ✓ $SERVICE is running"
    else
        echo "  ✗ $SERVICE is NOT running (status: $STATUS)"
    fi

    PORT_CHECK=$(vagrant ssh $VM -c "sudo ss -tlnp | grep :$PORT" 2>/dev/null | tr -d '\r')
    if [ -n "$PORT_CHECK" ]; then
        echo "  ✓ Port $PORT is open"
    else
        echo "  ✗ Port $PORT is NOT open"
    fi
    echo ""
}

echo "[1/5] db01 — MySQL"
check_service "db01" "mariadb" "3306"

echo "[2/5] mc01 — Memcached"
check_service "mc01" "memcached" "11211"

echo "[3/5] rmq01 — RabbitMQ"
check_service "rmq01" "rabbitmq-server" "5672"

echo "[4/5] app01 — Tomcat"
check_service "app01" "tomcat" "8080"

echo "[5/5] web01 — Nginx"
check_service "web01" "nginx" "80"

echo "================================================"
echo " End-to-end HTTP test"
echo "================================================"
HTTP=$(vagrant ssh web01 -c "curl -s -o /dev/null -w '%{http_code}' http://localhost" 2>/dev/null | tr -d '\r')
echo "  Nginx response code: $HTTP"
if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
    echo "  ✓ EduStack is live — open http://192.168.56.11"
else
    echo "  ✗ App not responding (code: $HTTP)"
fi
echo ""
echo "================================================"
vagrant status

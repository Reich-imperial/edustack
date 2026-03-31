#!/bin/bash
# ============================================================
# health-check.sh — verify all 5 EduStack AWS services
# Usage: bash health-check.sh
# ============================================================

RESOURCES=~/edustack-lift-shift/resources.env

if [ ! -f "$RESOURCES" ]; then
  echo "ERROR: resources.env not found."
  echo "Run build-edustack-aws.sh first."
  exit 1
fi

source $RESOURCES

echo "======================================================"
echo " EduStack AWS Health Check"
echo "======================================================"

# Check EC2 instance states
echo ""
echo "Instance states:"
check_instance() {
  local NAME=$1
  local ID=$2
  local STATE
  STATE=$(aws ec2 describe-instances \
    --instance-ids $ID \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null)
  if [ "$STATE" = "running" ]; then
    echo "  ✓ $NAME  ($ID)  $STATE"
  else
    echo "  ✗ $NAME  ($ID)  $STATE"
  fi
}

check_instance "web01  (Nginx)"      $WEB_INSTANCE_ID
check_instance "app01  (Tomcat)"     $APP_INSTANCE_ID
check_instance "db01   (MySQL)"      $DB_INSTANCE_ID
check_instance "mc01   (Memcached)"  $MC_INSTANCE_ID
check_instance "rmq01  (RabbitMQ)"   $RMQ_INSTANCE_ID

# Check setup logs via SSH
echo ""
echo "Setup log status:"
check_log() {
  local NAME=$1
  local USER=$2
  local IP=$3
  local LOG=$4
  local JUMP=$5

  if [ -n "$JUMP" ]; then
    DONE=$(ssh -i ~/.ssh/samson-key.pem \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -J ${JUMP} ${USER}@${IP} \
      "grep -c 'SETUP COMPLETE' ${LOG} 2>/dev/null || echo 0" 2>/dev/null)
  else
    DONE=$(ssh -i ~/.ssh/samson-key.pem \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      ${USER}@${IP} \
      "grep -c 'SETUP COMPLETE' ${LOG} 2>/dev/null || echo 0" 2>/dev/null)
  fi

  if [ "$DONE" = "1" ]; then
    echo "  ✓ $NAME setup complete"
  else
    echo "  … $NAME still provisioning (check log)"
  fi
}

BASTION="ubuntu@${WEB_PUBLIC_IP}"
check_log "web01"  "ubuntu"    "$WEB_PUBLIC_IP"  "/var/log/edustack-web01.log"
check_log "app01"  "ec2-user"  "$APP_IP"  "/var/log/edustack-app01.log"  "$BASTION"
check_log "db01"   "ec2-user"  "$DB_IP"   "/var/log/edustack-db01.log"   "$BASTION"
check_log "mc01"   "ec2-user"  "$MC_IP"   "/var/log/edustack-mc01.log"   "$BASTION"
check_log "rmq01"  "ec2-user"  "$RMQ_IP"  "/var/log/edustack-rmq01.log"  "$BASTION"

# Test HTTP response
echo ""
echo "HTTP test:"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 \
  http://$WEB_PUBLIC_IP 2>/dev/null)

if [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ]; then
  echo "  ✓ http://$WEB_PUBLIC_IP  →  HTTP $HTTP"
  echo "  ✓ EduStack is LIVE — open in browser"
  echo ""
  echo "  URL:   http://$WEB_PUBLIC_IP"
  echo "  Login: admin_vp / admin_vp"
else
  echo "  … http://$WEB_PUBLIC_IP  →  HTTP $HTTP"
  echo "  Tomcat may still be starting — wait and retry"
fi

echo ""
echo "SSH commands for debugging:"
echo "  web01:  ssh -i ~/.ssh/samson-key.pem ubuntu@$WEB_PUBLIC_IP"
echo "  app01:  ssh -i ~/.ssh/samson-key.pem -J ubuntu@$WEB_PUBLIC_IP ec2-user@$APP_IP"
echo "  db01:   ssh -i ~/.ssh/samson-key.pem -J ubuntu@$WEB_PUBLIC_IP ec2-user@$DB_IP"
echo "  mc01:   ssh -i ~/.ssh/samson-key.pem -J ubuntu@$WEB_PUBLIC_IP ec2-user@$MC_IP"
echo "  rmq01:  ssh -i ~/.ssh/samson-key.pem -J ubuntu@$WEB_PUBLIC_IP ec2-user@$RMQ_IP"
echo "======================================================"

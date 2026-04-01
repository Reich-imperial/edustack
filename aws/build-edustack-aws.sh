#!/bin/bash
# ============================================================
# EduStack AWS Lift-and-Shift — Version 2
# Fix: private subnet instances get all resources from S3
# No internet access required for private instances
#
# Architecture:
#   web01  (Nginx)     — public subnet  — t2.micro — Ubuntu 22.04
#   app01  (Tomcat)    — private subnet — t2.micro — Amazon Linux 2
#   db01   (MySQL)     — private subnet — t2.micro — Amazon Linux 2
#   mc01   (Memcached) — private subnet — t2.micro — Amazon Linux 2
#   rmq01  (RabbitMQ)  — private subnet — t2.micro — Amazon Linux 2
#
# All resources for private instances served from S3:
#   - Tomcat tar.gz uploaded from WSL to S3 to app01
#   - db_backup.sql uploaded from WSL to S3 to db01
#   - WAR built in WSL, uploaded to S3, downloaded by app01
#   - Java installed via amazon-linux-extras (AWS internal)
#   - RabbitMQ installed via epel (AWS internal)
#   - S3 VPC Gateway Endpoint allows private to S3 traffic
#
# Author: Samson Olanipekun (github.com/Reich-imperial)
# Usage:  bash build-edustack-aws.sh
# ============================================================

set -e

VPC_ID="vpc-029c24c39a502d3c3"
PUBLIC_SUBNET="subnet-01201d82bafedc6c0"
PRIVATE_SUBNET="subnet-01795487153e2a03d"
KEY_NAME="samson-key"
REGION="us-east-1"
ARTIFACT_BUCKET="edustack-artifacts-samson-unique-v2"

echo "======================================================"
echo " EduStack AWS Lift-and-Shift v2"
echo " All t2.micro — free tier eligible"
echo " Private instances pull all resources from S3"
echo "======================================================"

# Helper: get existing SG ID by name, returns empty string if not found
sg_exists() {
  local NAME=$1
  local RESULT
  RESULT=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=group-name,Values=$NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)
  if [ "$RESULT" = "None" ] || [ -z "$RESULT" ]; then
    echo ""
  else
    echo "$RESULT"
  fi
}

# ── Step 0: Build WAR locally ─────────────────────────────
echo ""
echo "[PRE] Checking EduStack WAR..."

WAR_FILE=$(ls ~/edustack/target/*.war 2>/dev/null | head -1)

WAR_IN_S3=$(aws s3 ls "s3://$ARTIFACT_BUCKET/EduStack.war" \
  2>/dev/null | wc -l)

if [ "$WAR_IN_S3" -gt "0" ]; then
  echo "  [SKIP] EduStack.war already exists in S3. Skipping build."
else
  echo "  [BUILD] WAR not found in S3. Building locally..."
  cd ~/edustack
  git checkout aws-lift-shift 2>/dev/null || git checkout -b aws-lift-shift
  export MAVEN_OPTS="-Xmx512m -Xms256m"
  mvn clean install -DskipTests -q
  WAR_FILE=$(ls ~/edustack/target/*.war 2>/dev/null | head -1)
  if [ -z "$WAR_FILE" ]; then
    echo "ERROR: WAR file not found after build."
    echo "Run: cd ~/edustack && mvn clean install -DskipTests"
    exit 1
  fi
  echo "  WAR built: $WAR_FILE"
fi

# ── Step 1: S3 bucket and uploads ─────────────────────────
echo ""
echo "[S3] Setting up artifact bucket..."

if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" 2>/dev/null; then
  echo "  Bucket $ARTIFACT_BUCKET already exists. Skipping creation."
else
  aws s3 mb "s3://$ARTIFACT_BUCKET" --region "$REGION"
  echo "  Bucket created: $ARTIFACT_BUCKET"
fi

# Upload WAR — skip if already in S3
# CRITICAL FIX: check WAR_IN_S3 not WAR_FILE to decide upload
WAR_IN_S3=$(aws s3 ls "s3://$ARTIFACT_BUCKET/EduStack.war" \
  2>/dev/null | wc -l)
if [ "$WAR_IN_S3" -gt "0" ]; then
  echo "  [SKIP] EduStack.war already present in S3."
elif [ -n "$WAR_FILE" ] && [ -f "$WAR_FILE" ]; then
  aws s3 cp "$WAR_FILE" "s3://$ARTIFACT_BUCKET/EduStack.war"
  echo "  Uploaded: EduStack.war"
else
  echo "ERROR: EduStack.war not in S3 and not found locally."
  echo "Delete the S3 bucket contents and rerun so the build step runs."
  exit 1
fi

# Upload db_backup.sql
if aws s3 ls "s3://$ARTIFACT_BUCKET/db_backup.sql" > /dev/null 2>&1; then
  echo "  [SKIP] db_backup.sql already present in S3."
else
  if [ ! -f ~/edustack/src/main/resources/db_backup.sql ]; then
    echo "ERROR: db_backup.sql not found at ~/edustack/src/main/resources/"
    exit 1
  fi
  aws s3 cp ~/edustack/src/main/resources/db_backup.sql \
    "s3://$ARTIFACT_BUCKET/db_backup.sql"
  echo "  Uploaded: db_backup.sql"
fi

# Upload Tomcat
if aws s3 ls "s3://$ARTIFACT_BUCKET/apache-tomcat-9.0.75.tar.gz" \
  > /dev/null 2>&1; then
  echo "  [SKIP] Tomcat archive already present in S3."
else
  echo "  Downloading Tomcat 9 locally..."
  rm -f /tmp/apache-tomcat-9.0.75.tar.gz
  if ! wget --show-progress --timeout=60 --tries=3 \
    -O /tmp/apache-tomcat-9.0.75.tar.gz \
    https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.75/bin/apache-tomcat-9.0.75.tar.gz; then
    echo "ERROR: Tomcat download failed. Check your internet connection."
    exit 1
  fi
  aws s3 cp /tmp/apache-tomcat-9.0.75.tar.gz \
    "s3://$ARTIFACT_BUCKET/apache-tomcat-9.0.75.tar.gz"
  echo "  Uploaded: apache-tomcat-9.0.75.tar.gz"
fi

# ── Step 2: S3 VPC Gateway Endpoint ──────────────────────
echo ""
echo "[VPC] Checking S3 VPC Gateway Endpoint..."

EXISTING_VPCE=$(aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
    "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text 2>/dev/null)

if [ -n "$EXISTING_VPCE" ] && [ "$EXISTING_VPCE" != "None" ]; then
  VPCE_ID=$EXISTING_VPCE
  echo "  [SKIP] S3 VPC endpoint already exists: $VPCE_ID"
else
  RT_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[*].RouteTableId' \
    --output text | tr '\t' ' ')
  VPCE_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --service-name "com.amazonaws.${REGION}.s3" \
    --route-table-ids $RT_IDS \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text)
  echo "  S3 VPC endpoint created: $VPCE_ID"
fi
echo "  Private instances can reach S3 without internet"

# ── Step 3: IAM role ──────────────────────────────────────
echo ""
echo "[IAM] Setting up EC2 role for S3 access..."

cat > /tmp/ec2-trust.json << 'TRUSTJSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
TRUSTJSON

if aws iam get-role --role-name edustack-ec2-role > /dev/null 2>&1; then
  echo "  [SKIP] IAM role already exists."
else
  aws iam create-role \
    --role-name edustack-ec2-role \
    --assume-role-policy-document file:///tmp/ec2-trust.json \
    --output text > /dev/null
  echo "  IAM role created."
fi

aws iam attach-role-policy \
  --role-name edustack-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  2>/dev/null || true

if aws iam get-instance-profile \
  --instance-profile-name edustack-ec2-profile > /dev/null 2>&1; then
  echo "  [SKIP] Instance profile already exists."
else
  aws iam create-instance-profile \
    --instance-profile-name edustack-ec2-profile > /dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name edustack-ec2-profile \
    --role-name edustack-ec2-role
  echo "  Instance profile created."
fi

echo "  Waiting 10s for IAM propagation..."
sleep 10

# ── Step 4: Security Groups ───────────────────────────────
echo ""
echo "[SG] Setting up security groups..."
MY_IP=$(curl -s ifconfig.me)

# web01-sg
EXISTING=$(sg_exists "edustack-web-sg")
if [ -n "$EXISTING" ]; then
  WEB_SG=$EXISTING
  echo "  [SKIP] edustack-web-sg: $WEB_SG"
else
  WEB_SG=$(aws ec2 create-security-group \
    --group-name edustack-web-sg \
    --description "EduStack web01 Nginx" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $WEB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress \
    --group-id $WEB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress \
    --group-id $WEB_SG --protocol tcp --port 22 --cidr ${MY_IP}/32
  aws ec2 create-tags --resources $WEB_SG \
    --tags Key=Name,Value=edustack-web-sg
  echo "  Created web-sg: $WEB_SG"
fi

# app01-sg
EXISTING=$(sg_exists "edustack-app-sg")
if [ -n "$EXISTING" ]; then
  APP_SG=$EXISTING
  echo "  [SKIP] edustack-app-sg: $APP_SG"
else
  APP_SG=$(aws ec2 create-security-group \
    --group-name edustack-app-sg \
    --description "EduStack app01 Tomcat" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $APP_SG --protocol tcp --port 8080 \
    --source-group $WEB_SG
  aws ec2 authorize-security-group-ingress \
    --group-id $APP_SG --protocol tcp --port 22 \
    --source-group $WEB_SG
  aws ec2 create-tags --resources $APP_SG \
    --tags Key=Name,Value=edustack-app-sg
  echo "  Created app-sg: $APP_SG"
fi

# db01-sg
EXISTING=$(sg_exists "edustack-db-sg")
if [ -n "$EXISTING" ]; then
  DB_SG=$EXISTING
  echo "  [SKIP] edustack-db-sg: $DB_SG"
else
  DB_SG=$(aws ec2 create-security-group \
    --group-name edustack-db-sg \
    --description "EduStack db01 MySQL" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $DB_SG --protocol tcp --port 3306 \
    --source-group $APP_SG
  aws ec2 authorize-security-group-ingress \
    --group-id $DB_SG --protocol tcp --port 22 \
    --source-group $WEB_SG
  aws ec2 create-tags --resources $DB_SG \
    --tags Key=Name,Value=edustack-db-sg
  echo "  Created db-sg: $DB_SG"
fi

# mc01-sg
EXISTING=$(sg_exists "edustack-mc-sg")
if [ -n "$EXISTING" ]; then
  MC_SG=$EXISTING
  echo "  [SKIP] edustack-mc-sg: $MC_SG"
else
  MC_SG=$(aws ec2 create-security-group \
    --group-name edustack-mc-sg \
    --description "EduStack mc01 Memcached" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $MC_SG --protocol tcp --port 11211 \
    --source-group $APP_SG
  aws ec2 authorize-security-group-ingress \
    --group-id $MC_SG --protocol tcp --port 22 \
    --source-group $WEB_SG
  aws ec2 create-tags --resources $MC_SG \
    --tags Key=Name,Value=edustack-mc-sg
  echo "  Created mc-sg: $MC_SG"
fi

# rmq01-sg
EXISTING=$(sg_exists "edustack-rmq-sg")
if [ -n "$EXISTING" ]; then
  RMQ_SG=$EXISTING
  echo "  [SKIP] edustack-rmq-sg: $RMQ_SG"
else
  RMQ_SG=$(aws ec2 create-security-group \
    --group-name edustack-rmq-sg \
    --description "EduStack rmq01 RabbitMQ" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $RMQ_SG --protocol tcp --port 5672 \
    --source-group $APP_SG
  aws ec2 authorize-security-group-ingress \
    --group-id $RMQ_SG --protocol tcp --port 15672 \
    --source-group $WEB_SG
  aws ec2 authorize-security-group-ingress \
    --group-id $RMQ_SG --protocol tcp --port 22 \
    --source-group $WEB_SG
  aws ec2 create-tags --resources $RMQ_SG \
    --tags Key=Name,Value=edustack-rmq-sg
  echo "  Created rmq-sg: $RMQ_SG"
fi

echo "  SGs ready: web=$WEB_SG app=$APP_SG db=$DB_SG mc=$MC_SG rmq=$RMQ_SG"

# ── Get AMIs ──────────────────────────────────────────────
echo ""
echo "[AMI] Finding latest AMIs..."

AL2_AMI=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
    "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text)

UBUNTU_AMI=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text)

echo "  AL2    (backend): $AL2_AMI"
echo "  Ubuntu (web01):   $UBUNTU_AMI"

# ── Step 5: Launch db01 ───────────────────────────────────
echo ""
echo "[db01] Launching MySQL..."

cat > /tmp/db01-userdata.sh << USERDATA
#!/bin/bash
exec > /var/log/edustack-db01.log 2>&1
set -xe

yum update -y
yum install -y mariadb-server

systemctl start mariadb
systemctl enable mariadb

mysql -u root << 'SQL'
UPDATE mysql.user SET Password=PASSWORD('admin123') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS accounts;
GRANT ALL PRIVILEGES ON accounts.* TO 'admin'@'%' IDENTIFIED BY 'admin123';
FLUSH PRIVILEGES;
SQL

aws s3 cp s3://${ARTIFACT_BUCKET}/db_backup.sql \
  /tmp/db_backup.sql --region ${REGION}

mysql -u root -padmin123 accounts < /tmp/db_backup.sql

cat >> /etc/my.cnf << 'CNF'
[mysqld]
bind-address = 0.0.0.0
CNF

systemctl restart mariadb
echo "db01 SETUP COMPLETE"
USERDATA

DB_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AL2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $PRIVATE_SUBNET \
  --security-group-ids $DB_SG \
  --iam-instance-profile Name=edustack-ec2-profile \
  --user-data file:///tmp/db01-userdata.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=edustack-db01}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "  db01: $DB_INSTANCE_ID"

# ── Step 6: Launch mc01 ───────────────────────────────────
echo ""
echo "[mc01] Launching Memcached..."

cat > /tmp/mc01-userdata.sh << 'USERDATA'
#!/bin/bash
exec > /var/log/edustack-mc01.log 2>&1
set -xe

yum update -y
yum install -y memcached

sed -i \
  's/OPTIONS="-l 127.0.0.1,-\[::1\]"/OPTIONS="-l 0.0.0.0"/' \
  /etc/sysconfig/memcached 2>/dev/null || true

grep -q 'OPTIONS="-l 0.0.0.0"' /etc/sysconfig/memcached 2>/dev/null || \
  echo 'OPTIONS="-l 0.0.0.0"' >> /etc/sysconfig/memcached

systemctl start memcached
systemctl enable memcached
echo "mc01 SETUP COMPLETE"
USERDATA

MC_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AL2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $PRIVATE_SUBNET \
  --security-group-ids $MC_SG \
  --iam-instance-profile Name=edustack-ec2-profile \
  --user-data file:///tmp/mc01-userdata.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=edustack-mc01}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "  mc01: $MC_INSTANCE_ID"

# ── Step 7: Launch rmq01 ──────────────────────────────────
echo ""
echo "[rmq01] Launching RabbitMQ..."

cat > /tmp/rmq01-userdata.sh << 'USERDATA'
#!/bin/bash
exec > /var/log/edustack-rmq01.log 2>&1
set -xe

yum update -y
amazon-linux-extras install epel -y
yum install -y erlang rabbitmq-server

systemctl start rabbitmq-server
systemctl enable rabbitmq-server

cat > /etc/rabbitmq/rabbitmq.config << 'RMQCONF'
[{rabbit, [{loopback_users, []}]}].
RMQCONF

rabbitmqctl add_user test test
rabbitmqctl set_user_tags test administrator
rabbitmqctl set_permissions -p / test ".*" ".*" ".*"

rabbitmq-plugins enable rabbitmq_management
systemctl restart rabbitmq-server
echo "rmq01 SETUP COMPLETE"
USERDATA

RMQ_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AL2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $PRIVATE_SUBNET \
  --security-group-ids $RMQ_SG \
  --iam-instance-profile Name=edustack-ec2-profile \
  --user-data file:///tmp/rmq01-userdata.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=edustack-rmq01}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "  rmq01: $RMQ_INSTANCE_ID"

# ── Wait for backend private IPs ──────────────────────────
echo ""
echo "Waiting 60s for backend instances to get private IPs..."
sleep 60

DB_IP=$(aws ec2 describe-instances \
  --instance-ids $DB_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)
MC_IP=$(aws ec2 describe-instances \
  --instance-ids $MC_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)
RMQ_IP=$(aws ec2 describe-instances \
  --instance-ids $RMQ_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

for VAR_NAME in DB_IP MC_IP RMQ_IP; do
  VAL="${!VAR_NAME}"
  if [ -z "$VAL" ] || [ "$VAL" = "None" ]; then
    echo "ERROR: Could not get private IP for $VAR_NAME"
    echo "Check AWS console — the instance may have failed to launch"
    exit 1
  fi
done

echo "  db01  private IP: $DB_IP"
echo "  mc01  private IP: $MC_IP"
echo "  rmq01 private IP: $RMQ_IP"

# ── Step 8: Launch app01 ──────────────────────────────────
echo ""
echo "[app01] Launching Tomcat — all resources from S3..."

cat > /tmp/application.properties << APPPROPS
#JDBC Configuration
jdbc.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.url=jdbc:mysql://${DB_IP}:3306/accounts?useUnicode=true&characterEncoding=UTF-8&zeroDateTimeBehavior=convertToNull
jdbc.username=admin
jdbc.password=admin123

#Memcached
memcached.active.host=${MC_IP}
memcached.active.port=11211
memcached.standBy.host=127.0.0.2
memcached.standBy.port=11211

#RabbitMQ
rabbitmq.address=${RMQ_IP}
rabbitmq.port=5672
rabbitmq.username=test
rabbitmq.password=test

#Elasticsearch
elasticsearch.host=localhost
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode

#Spring MVC
spring.mvc.view.prefix=/WEB-INF/views/
spring.mvc.view.suffix=.jsp

spring.security.user.name=admin_vp
spring.security.user.password=admin_vp
spring.security.user.roles=ADMIN

logging.level.org.springframework.security=DEBUG
spring.jpa.show-sql=false
APPPROPS

# Always overwrite application.properties in S3 with latest IPs
aws s3 cp /tmp/application.properties \
  "s3://$ARTIFACT_BUCKET/application.properties"
echo "  application.properties uploaded with real private IPs"

cat > /tmp/app01-userdata.sh << USERDATA
#!/bin/bash
exec > /var/log/edustack-app01.log 2>&1
set -xe

# Java 11 via amazon-linux-extras — AWS internal, no internet needed
amazon-linux-extras install java-openjdk11 -y
java -version

# Download Tomcat from S3 via VPC endpoint
aws s3 cp s3://${ARTIFACT_BUCKET}/apache-tomcat-9.0.75.tar.gz \
  /tmp/apache-tomcat-9.0.75.tar.gz --region ${REGION}

cd /tmp
tar xzf apache-tomcat-9.0.75.tar.gz

useradd -r -m -U -d /opt/tomcat -s /bin/false tomcat 2>/dev/null || true
mkdir -p /opt/tomcat
cp -r /tmp/apache-tomcat-9.0.75/* /opt/tomcat/
chown -R tomcat:tomcat /opt/tomcat
chmod +x /opt/tomcat/bin/*.sh

JAVA_HOME_PATH=\$(dirname \$(dirname \$(readlink -f \$(which java))))
echo "Java home: \$JAVA_HOME_PATH"

cat > /etc/systemd/system/tomcat.service << SERVICE
[Unit]
Description=EduStack Apache Tomcat
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=\${JAVA_HOME_PATH}"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

# Download WAR from S3
aws s3 cp s3://${ARTIFACT_BUCKET}/EduStack.war \
  /opt/tomcat/webapps/ROOT.war --region ${REGION}
chown tomcat:tomcat /opt/tomcat/webapps/ROOT.war

systemctl daemon-reload
systemctl start tomcat
systemctl enable tomcat

# Poll until WAR unpacks
echo "Waiting for WAR to unpack..."
for i in \$(seq 1 20); do
  if [ -d /opt/tomcat/webapps/ROOT/WEB-INF/classes ]; then
    echo "WAR unpacked after \${i} attempts"
    break
  fi
  if [ "\$i" -eq "20" ]; then
    echo "ERROR: WAR did not unpack after 20 attempts (5 mins)"
    exit 1
  fi
  echo "Attempt \${i}/20 — waiting 15s..."
  sleep 15
done

# Inject application.properties with real IPs from S3
aws s3 cp s3://${ARTIFACT_BUCKET}/application.properties \
  /opt/tomcat/webapps/ROOT/WEB-INF/classes/application.properties \
  --region ${REGION}
chown tomcat:tomcat \
  /opt/tomcat/webapps/ROOT/WEB-INF/classes/application.properties

systemctl restart tomcat
echo "app01 SETUP COMPLETE"
USERDATA

APP_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AL2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $PRIVATE_SUBNET \
  --security-group-ids $APP_SG \
  --iam-instance-profile Name=edustack-ec2-profile \
  --user-data file:///tmp/app01-userdata.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=edustack-app01}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

APP_IP=$(aws ec2 describe-instances \
  --instance-ids $APP_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

if [ -z "$APP_IP" ] || [ "$APP_IP" = "None" ]; then
  echo "ERROR: Could not get private IP for app01"
  exit 1
fi
echo "  app01: $APP_INSTANCE_ID  IP: $APP_IP"

# ── Step 9: Launch web01 ──────────────────────────────────
echo ""
echo "[web01] Launching Nginx reverse proxy..."

cat > /tmp/web01-userdata.sh << USERDATA
#!/bin/bash
exec > /var/log/edustack-web01.log 2>&1
set -xe

apt update -y
apt install -y nginx

cat > /etc/nginx/sites-available/edustack << 'NGINXCONF'
upstream eduapp {
  server ${APP_IP}:8080;
}

server {
  listen 80;
  server_name _;

  location / {
    proxy_pass          http://eduapp;
    proxy_set_header    Host \$host;
    proxy_set_header    X-Real-IP \$remote_addr;
    proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_connect_timeout 60s;
    proxy_read_timeout    60s;
    proxy_send_timeout    60s;
  }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/edustack \
       /etc/nginx/sites-enabled/edustack
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx
echo "web01 SETUP COMPLETE"
USERDATA

WEB_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $UBUNTU_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $PUBLIC_SUBNET \
  --security-group-ids $WEB_SG \
  --user-data file:///tmp/web01-userdata.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=edustack-web01}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "  web01: $WEB_INSTANCE_ID"

echo ""
echo "Waiting for web01 to be running..."
aws ec2 wait instance-running --instance-ids $WEB_INSTANCE_ID

WEB_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $WEB_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [ -z "$WEB_PUBLIC_IP" ] || [ "$WEB_PUBLIC_IP" = "None" ]; then
  echo "ERROR: Could not get public IP for web01"
  exit 1
fi

# ── Save all resource IDs ─────────────────────────────────
mkdir -p ~/edustack-lift-shift
cat > ~/edustack-lift-shift/resources.env << ENVFILE
VPC_ID=${VPC_ID}
ARTIFACT_BUCKET=${ARTIFACT_BUCKET}
VPCE_ID=${VPCE_ID}
WEB_INSTANCE_ID=${WEB_INSTANCE_ID}
APP_INSTANCE_ID=${APP_INSTANCE_ID}
DB_INSTANCE_ID=${DB_INSTANCE_ID}
MC_INSTANCE_ID=${MC_INSTANCE_ID}
RMQ_INSTANCE_ID=${RMQ_INSTANCE_ID}
WEB_SG=${WEB_SG}
APP_SG=${APP_SG}
DB_SG=${DB_SG}
MC_SG=${MC_SG}
RMQ_SG=${RMQ_SG}
DB_IP=${DB_IP}
MC_IP=${MC_IP}
RMQ_IP=${RMQ_IP}
APP_IP=${APP_IP}
WEB_PUBLIC_IP=${WEB_PUBLIC_IP}
ENVFILE

echo ""
echo "======================================================"
echo " EduStack Lift-and-Shift v2 — ALL LAUNCHED"
echo "======================================================"
echo ""
printf " %-6s  %-22s  %-16s  %s\n" "SVC" "INSTANCE ID" "IP" "SUBNET"
printf " %-6s  %-22s  %-16s  %s\n" "------" "--------------------" "---------------" "-------"
printf " %-6s  %-22s  %-16s  %s\n" "web01"  "$WEB_INSTANCE_ID" "$WEB_PUBLIC_IP" "PUBLIC"
printf " %-6s  %-22s  %-16s  %s\n" "app01"  "$APP_INSTANCE_ID" "$APP_IP"        "PRIVATE"
printf " %-6s  %-22s  %-16s  %s\n" "db01"   "$DB_INSTANCE_ID"  "$DB_IP"         "PRIVATE"
printf " %-6s  %-22s  %-16s  %s\n" "mc01"   "$MC_INSTANCE_ID"  "$MC_IP"         "PRIVATE"
printf " %-6s  %-22s  %-16s  %s\n" "rmq01"  "$RMQ_INSTANCE_ID" "$RMQ_IP"        "PRIVATE"
echo ""
echo "------------------------------------------------------"
echo " How private instances got their resources:"
echo "  Java    — amazon-linux-extras (AWS internal repos)"
echo "  Tomcat  — S3 via VPC Gateway Endpoint"
echo "  WAR     — S3 via VPC Gateway Endpoint"
echo "  Schema  — S3 via VPC Gateway Endpoint"
echo "  Packages— yum/epel (Amazon Linux internal mirrors)"
echo "------------------------------------------------------"
echo ""
echo " app01 takes 10-15 mins to fully start"
echo " Tomcat unpacks the WAR then restarts with correct IPs"
echo ""
echo " Monitor app01:"
echo "  ssh -i ~/.ssh/samson-key.pem ubuntu@${WEB_PUBLIC_IP}"
echo "  ssh -i ~/.ssh/samson-key.pem ec2-user@${APP_IP}"
echo "  sudo tail -f /var/log/edustack-app01.log"
echo ""
echo " Health check after 15 mins:"
echo "  bash ~/edustack-lift-shift/health-check.sh"
echo ""
echo " Browser test:"
echo "  http://${WEB_PUBLIC_IP}"
echo "  Login: admin_vp / admin_vp"
echo "======================================================"
#!/bin/bash
# ============================================================
# EduStack AWS Lift-and-Shift
# Branch: aws-lift-shift
# Repo: github.com/Reich-imperial/edustack
#
# Architecture:
#   web01 (Nginx)     — public subnet  — t2.micro
#   app01 (Tomcat)    — private subnet — t2.micro
#   db01  (MySQL)     — private subnet — t2.micro
#   mc01  (Memcached) — private subnet — t2.micro
#   rmq01 (RabbitMQ)  — private subnet — t2.micro
#
# All t2.micro — free tier eligible
# WAR is built locally in WSL and uploaded to S3
# EC2 instances download from S3 — no Maven on EC2
#
# Author: Samson Olanipekun (github.com/Reich-imperial)
# Usage:  bash build-edustack-aws.sh
# ============================================================

set -e

# ── Configuration ─────────────────────────────────────────
VPC_ID="vpc-029c24c39a502d3c3"
PUBLIC_SUBNET="subnet-01201d82bafedc6c0"
PRIVATE_SUBNET="subnet-01795487153e2a03d"
KEY_NAME="samson-key"
REGION="us-east-1"
ARTIFACT_BUCKET="edustack-artifacts-$(date +%s)"

echo "======================================================"
echo " EduStack AWS Lift-and-Shift"
echo " All t2.micro — free tier eligible"
echo "======================================================"

# ── Pre-flight: build WAR locally ─────────────────────────
echo ""
echo "[PRE] Building EduStack WAR locally in WSL..."
echo "      This avoids Maven on EC2 — all t2.micro possible"

cd ~/edustack

# Ensure we are on aws-lift-shift branch
git checkout aws-lift-shift 2>/dev/null || git checkout -b aws-lift-shift

# Build WAR with Maven locally
export MAVEN_OPTS="-Xmx512m -Xms256m"
mvn clean install -DskipTests -q

WAR_FILE=$(ls ~/edustack/target/*.war | head -1)
if [ -z "$WAR_FILE" ]; then
  echo "ERROR: WAR file not found. Maven build may have failed."
  echo "Check: cd ~/edustack && mvn clean install -DskipTests"
  exit 1
fi
echo "  WAR built: $WAR_FILE"

# ── Create S3 artifact bucket ─────────────────────────────
echo ""
echo "[S3] Uploading WAR to S3 artifact bucket..."
aws s3 mb s3://$ARTIFACT_BUCKET --region $REGION
aws s3 cp $WAR_FILE s3://$ARTIFACT_BUCKET/EduStack.war
echo "  Artifact: s3://$ARTIFACT_BUCKET/EduStack.war"

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

# ── IAM role so EC2 can read from S3 ──────────────────────
echo ""
echo "[IAM] Creating EC2 role for S3 access..."

# Trust policy — allows EC2 to assume this role
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

aws iam create-role \
  --role-name edustack-ec2-role \
  --assume-role-policy-document file:///tmp/ec2-trust.json \
  --output text > /dev/null 2>/dev/null || true

aws iam attach-role-policy \
  --role-name edustack-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name edustack-ec2-profile 2>/dev/null || true

aws iam add-role-to-instance-profile \
  --instance-profile-name edustack-ec2-profile \
  --role-name edustack-ec2-role 2>/dev/null || true

echo "  Role: edustack-ec2-role (S3 read access)"
echo "  Waiting 10s for IAM propagation..."
sleep 10

# ── Security Groups ───────────────────────────────────────
echo ""
echo "[SG] Creating security groups..."
MY_IP=$(curl -s ifconfig.me)

# web01-sg
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
echo "  web-sg:  $WEB_SG"

# app01-sg
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
echo "  app-sg:  $APP_SG"

# db01-sg
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
echo "  db-sg:   $DB_SG"

# mc01-sg
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
echo "  mc-sg:   $MC_SG"

# rmq01-sg
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
echo "  rmq-sg:  $RMQ_SG"

# ── Launch db01 ───────────────────────────────────────────
echo ""
echo "[db01] Launching MySQL..."

cat > /tmp/db01-userdata.sh << 'USERDATA'
#!/bin/bash
exec > /var/log/edustack-db01.log 2>&1
set -xe
yum update -y
yum install -y mariadb-server git

systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB and create database
mysql -u root << 'SQL'
UPDATE mysql.user SET Password=PASSWORD('admin123') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS accounts;
GRANT ALL PRIVILEGES ON accounts.* TO 'admin'@'%' IDENTIFIED BY 'admin123';
FLUSH PRIVILEGES;
SQL

# Load vprofile schema from EduStack GitHub repo
cd /tmp
git clone https://github.com/Reich-imperial/edustack.git
mysql -u root -padmin123 accounts \
  < /tmp/edustack/src/main/resources/db_backup.sql

# Allow remote connections
cat >> /etc/my.cnf << 'CNF'
[mysqld]
bind-address = 0.0.0.0
CNF

systemctl restart mariadb
echo "db01 SETUP COMPLETE" >> /var/log/edustack-db01.log
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

# ── Launch mc01 ───────────────────────────────────────────
echo ""
echo "[mc01] Launching Memcached..."

cat > /tmp/mc01-userdata.sh << 'USERDATA'
#!/bin/bash
exec > /var/log/edustack-mc01.log 2>&1
set -xe
yum update -y
yum install -y memcached

# Bind to all interfaces so app01 can connect
sed -i \
  's/OPTIONS="-l 127.0.0.1,-\[::1\]"/OPTIONS="-l 0.0.0.0"/' \
  /etc/sysconfig/memcached

# If sed didn't match, write it directly
grep -q 'OPTIONS="-l 0.0.0.0"' /etc/sysconfig/memcached || \
  echo 'OPTIONS="-l 0.0.0.0"' >> /etc/sysconfig/memcached

systemctl start memcached
systemctl enable memcached
echo "mc01 SETUP COMPLETE" >> /var/log/edustack-mc01.log
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

# ── Launch rmq01 ──────────────────────────────────────────
echo ""
echo "[rmq01] Launching RabbitMQ..."

cat > /tmp/rmq01-userdata.sh << 'USERDATA'
#!/bin/bash
exec > /var/log/edustack-rmq01.log 2>&1
set -xe
yum update -y

# Install Erlang from Amazon Linux extras
amazon-linux-extras install epel -y
yum install -y erlang

# Add RabbitMQ repo and install
curl -fsSL https://packagecloud.io/rabbitmq/rabbitmq-server/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/rabbitmq.gpg
curl -s https://packagecloud.io/install/repositories/rabbitmq/rabbitmq-server/script.rpm.sh \
  | bash
yum install -y rabbitmq-server

systemctl start rabbitmq-server
systemctl enable rabbitmq-server

# Allow connections from non-localhost
cat > /etc/rabbitmq/rabbitmq.config << 'RMQCONF'
[{rabbit, [{loopback_users, []}]}].
RMQCONF

# Create app user (vprofile default credentials)
rabbitmqctl add_user test test
rabbitmqctl set_user_tags test administrator
rabbitmqctl set_permissions -p / test ".*" ".*" ".*"

rabbitmq-plugins enable rabbitmq_management
systemctl restart rabbitmq-server
echo "rmq01 SETUP COMPLETE" >> /var/log/edustack-rmq01.log
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

# ── Wait for private IPs ──────────────────────────────────
echo ""
echo "Waiting 60s for backend IPs to be assigned..."
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

echo "  db01  private IP: $DB_IP"
echo "  mc01  private IP: $MC_IP"
echo "  rmq01 private IP: $RMQ_IP"

# ── Launch app01 ──────────────────────────────────────────
echo ""
echo "[app01] Launching Tomcat (WAR from S3)..."

# Write application.properties with real AWS private IPs
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

#Elasticsearch (required by Spring context even if unused)
elasticsearch.host=localhost
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode

#Spring MVC
spring.mvc.view.prefix=/WEB-INF/views/
spring.mvc.view.suffix=.jsp

#Default admin credentials
spring.security.user.name=admin_vp
spring.security.user.password=admin_vp
spring.security.user.roles=ADMIN

logging.level.org.springframework.security=DEBUG
spring.jpa.show-sql=false
APPPROPS

# Upload application.properties to S3
aws s3 cp /tmp/application.properties \
  s3://$ARTIFACT_BUCKET/application.properties
echo "  application.properties uploaded to S3"

# app01 user data: download WAR + properties from S3, deploy to Tomcat
cat > /tmp/app01-userdata.sh << USERDATA
#!/bin/bash
exec > /var/log/edustack-app01.log 2>&1
set -xe

# Install Java 11 and Tomcat
yum update -y
yum install -y java-11-openjdk wget

# Download and install Tomcat 9
cd /tmp
wget -q https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.75/bin/apache-tomcat-9.0.75.tar.gz
tar xzf apache-tomcat-9.0.75.tar.gz

useradd -r -m -U -d /opt/tomcat -s /bin/false tomcat 2>/dev/null || true
mkdir -p /opt/tomcat
cp -r /tmp/apache-tomcat-9.0.75/* /opt/tomcat/
chown -R tomcat:tomcat /opt/tomcat
chmod +x /opt/tomcat/bin/*.sh

# Systemd service
cat > /etc/systemd/system/tomcat.service << 'SERVICE'
[Unit]
Description=EduStack Apache Tomcat
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/jre"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

# Download WAR and application.properties from S3
# IAM role provides credentials — no keys needed
aws s3 cp s3://${ARTIFACT_BUCKET}/EduStack.war \
  /opt/tomcat/webapps/ROOT.war
aws s3 cp s3://${ARTIFACT_BUCKET}/application.properties \
  /opt/tomcat/webapps/application.properties.tmp

chown tomcat:tomcat /opt/tomcat/webapps/ROOT.war

systemctl daemon-reload
systemctl start tomcat
systemctl enable tomcat

# Wait for WAR to unpack then inject application.properties
sleep 30
if [ -d /opt/tomcat/webapps/ROOT/WEB-INF/classes ]; then
  cp /opt/tomcat/webapps/application.properties.tmp \
    /opt/tomcat/webapps/ROOT/WEB-INF/classes/application.properties
  chown tomcat:tomcat \
    /opt/tomcat/webapps/ROOT/WEB-INF/classes/application.properties
  systemctl restart tomcat
fi

echo "app01 SETUP COMPLETE" >> /var/log/edustack-app01.log
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
echo "  app01: $APP_INSTANCE_ID  IP: $APP_IP"
echo "  WAR downloaded from S3 — no Maven on EC2"

# ── Launch web01 ──────────────────────────────────────────
echo ""
echo "[web01] Launching Nginx..."

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
echo "web01 SETUP COMPLETE" >> /var/log/edustack-web01.log
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

# ── Get web01 public IP ───────────────────────────────────
echo ""
echo "Waiting for web01 to start..."
aws ec2 wait instance-running --instance-ids $WEB_INSTANCE_ID

WEB_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $WEB_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# ── Save all resource IDs ─────────────────────────────────
mkdir -p ~/edustack-lift-shift
cat > ~/edustack-lift-shift/resources.env << ENVFILE
VPC_ID=${VPC_ID}
ARTIFACT_BUCKET=${ARTIFACT_BUCKET}
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
echo " EduStack Lift-and-Shift — ALL LAUNCHED"
echo "======================================================"
echo ""
printf " %-6s %-22s %-16s %s\n" "SVC" "INSTANCE ID" "IP" "SUBNET"
printf " %-6s %-22s %-16s %s\n" "web01" "$WEB_INSTANCE_ID" "$WEB_PUBLIC_IP" "PUBLIC"
printf " %-6s %-22s %-16s %s\n" "app01" "$APP_INSTANCE_ID" "$APP_IP" "PRIVATE"
printf " %-6s %-22s %-16s %s\n" "db01"  "$DB_INSTANCE_ID"  "$DB_IP"  "PRIVATE"
printf " %-6s %-22s %-16s %s\n" "mc01"  "$MC_INSTANCE_ID"  "$MC_IP"  "PRIVATE"
printf " %-6s %-22s %-16s %s\n" "rmq01" "$RMQ_INSTANCE_ID" "$RMQ_IP" "PRIVATE"
echo ""
echo "------------------------------------------------------"
echo " All instances are t2.micro — free tier eligible"
echo " WAR deployed from S3 — no Maven on any EC2 instance"
echo "------------------------------------------------------"
echo ""
echo " Wait 10-15 minutes for user data to complete"
echo " Then run: bash health-check.sh"
echo ""
echo " Monitor app01 progress:"
echo " ssh -i ~/.ssh/samson-key.pem ubuntu@${WEB_PUBLIC_IP}"
echo " then: ssh -i ~/.ssh/samson-key.pem ec2-user@${APP_IP}"
echo " then: sudo tail -f /var/log/edustack-app01.log"
echo ""
echo " Test when ready:"
echo " http://${WEB_PUBLIC_IP}"
echo " Login: admin_vp / admin_vp"
echo "======================================================"

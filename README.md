# EduStack — Multi-Tier University Student Portal

[![CI/CD Pipeline](https://github.com/Reich-imperial/edustack/actions/workflows/pipeline.yml/badge.svg)](https://github.com/Reich-imperial/edustack/actions/workflows/pipeline.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED.svg?logo=docker)](docker-compose.yml)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-manifests-326CE5.svg?logo=kubernetes)](kubernetes/)
[![Security: Snyk](https://img.shields.io/badge/security-snyk-4C4A73.svg)](https://snyk.io)
[![Security: Trivy](https://img.shields.io/badge/container-trivy-1904DA.svg)](https://trivy.dev)

> A production-grade, multi-tier web application simulating a university student portal — built to demonstrate end-to-end DevOps engineering skills across five deployment stages..

---

## What is EduStack?

EduStack is a personalised adaptation of the classic multi-tier DevOps project architecture. It runs a university student portal (courses, grades, announcements) across five interconnected services, each running on a dedicated host:

| Service | Technology | Role |
|---------|-----------|------|
| **web01** | Nginx | Reverse proxy / load balancer |
| **app01** | Apache Tomcat 10 | Java application server |
| **db01** | MySQL / MariaDB | Relational data store |
| **mc01** | Memcached | Database query cache |
| **rmq01** | RabbitMQ | Async notification message broker |

The same application is deployed five different ways — from bare VMs to Kubernetes — each one building on the last. This mirrors how real DevOps teams evolve infrastructure over time.

---

## Architecture

```
Student Browser
      │
      ▼  HTTP :80
  ┌─────────────┐
  │  web01      │  Nginx reverse proxy
  │  (Ubuntu)   │  Receives all incoming traffic
  └──────┬──────┘
         │  :8080
         ▼
  ┌─────────────┐
  │  app01      │  Apache Tomcat — runs EduStack.war
  │  (CentOS)   │  Java 17 + Spring MVC
  └──┬───┬───┬──┘
     │   │   │
     │   │   └──────────────────────────┐
     │   │                              ▼
     │   │  :11211              ┌──────────────┐
     │   └──────────────────►  │  mc01        │
     │                         │  Memcached   │  Cache layer — reduces
     │  :3306                  │  (CentOS)    │  MySQL round trips
     ▼                         └──────────────┘
  ┌─────────────┐
  │  db01       │  MariaDB — stores students,
  │  (CentOS)   │  courses, grades, announcements
  └─────────────┘

     ▼  :5672
  ┌─────────────┐
  │  rmq01      │  RabbitMQ — handles async events
  │  (CentOS)   │  (grade updates, email notifications)
  └─────────────┘
```

**Request flow:**
1. Student opens browser → hits Nginx on port 80
2. Nginx proxies request to Tomcat on port 8080
3. Tomcat checks Memcached — if data is cached, returns immediately
4. On cache miss, Tomcat queries MySQL database
5. Result stored in Memcached for next request
6. Grade/announcement events published to RabbitMQ asynchronously

---

## Project Branches — Deployment Stages

This repository uses branches to represent progressive deployment stages. Each branch is a complete, working deployment of the same application:

| Branch | Stage | Description |
|--------|-------|-------------|
| `main` | Production CI/CD | GitHub Actions → ECR → EC2 |
| `local-manual` | Local VMs | Step-by-step manual setup with Vagrant |
| `local-auto` | Local VMs | Fully automated Vagrant provisioning |
| `aws-lift-shift` | AWS EC2 | Same stack migrated to cloud |
| `containerised` | Docker | All services in containers via Compose |
| `kubernetes` | K8s | Full Kubernetes deployment with HPA |

---

## Prerequisites

Ensure the following are installed before starting:

```bash
# Check versions
vagrant --version     # >= 2.3
VBoxManage --version  # >= 7.0
docker --version      # >= 24.0
kubectl version       # >= 1.28
mvn --version         # >= 3.8  (Apache Maven)
java --version        # >= 17   (OpenJDK)
aws --version         # >= 2.0  (AWS CLI)
```

---

## Quick Start

### Option A — Local setup (Vagrant, fully automated)

```bash
# Clone the repo
git clone https://github.com/Reich-imperial/edustack.git
cd edustack

# Switch to automated branch
git checkout local-auto
cd vagrant/Automated_Provisioning

# Boot all 5 VMs (takes ~10-15 mins on first run)
vagrant up

# Verify all VMs are running
vagrant status
```
> **Note:** After `vagrant up` completes, if the app returns 404 or login
> fails, refer to the Troubleshooting section below. The most common issues
> are the Elasticsearch placeholder and database schema — both are documented
> with exact fixes.

Open your browser at: **http://192.168.56.11**

Login with demo credentials:
- **Admin:** `admin_vp` / `admin_vp`

---

### Option B — Docker Compose (fastest)

```bash
git clone https://github.com/Reich-imperial/edustack.git
cd edustack
git checkout containerised

# Start all services
docker compose up -d

# Check all containers are healthy
docker compose ps

# Watch logs
docker compose logs -f

# Access the portal
open http://localhost

# RabbitMQ management UI
open http://localhost:15672   # user: edustack / pass: edustack@2026
```

---

### Option C — Kubernetes

```bash
git clone https://github.com/Reich-imperial/edustack.git
cd edustack

# Create namespace and deploy all resources
kubectl apply -f kubernetes/edustack-k8s.yml

# Watch pods come up
kubectl get pods -n edustack -w

# Get the LoadBalancer external IP
kubectl get svc edustack-web-svc -n edustack

# Check logs
kubectl logs -n edustack -l app=edustack-app --tail=50
```

---

## Manual VM Setup Guide

Use the `local-manual` branch to practise provisioning each service by hand. This is the best way to deeply understand what each service does before automating it.

### Provisioning order (always follow this sequence)

```
1. db01    — Database must be ready before the app can connect
2. mc01    — Cache must be running before app starts
3. rmq01   — Message broker must be up before app starts
4. app01   — Application server (depends on db01, mc01, rmq01)
5. web01   — Reverse proxy (last, as it points to app01)
```

### db01 — MySQL / MariaDB

```bash
vagrant ssh db01

# Install MariaDB
sudo dnf update -y && sudo dnf install -y mariadb-server
sudo systemctl start mariadb && sudo systemctl enable mariadb

# Secure and configure
sudo mysqladmin -u root password 'eduAdmin@2026'
sudo mysql -u root -p'eduAdmin@2026' -e "CREATE DATABASE edustack;"
sudo mysql -u root -p'eduAdmin@2026' -e \
  "GRANT ALL ON edustack.* TO 'eduadmin'@'app01' IDENTIFIED BY 'eduAdmin@2026';"

# Load schema
sudo mysql -u root -p'eduAdmin@2026' edustack < /vagrant/src/main/resources/db_setup.sql

# Open firewall
sudo firewall-cmd --add-port=3306/tcp --permanent && sudo firewall-cmd --reload
```

### mc01 — Memcached

```bash
vagrant ssh mc01

sudo dnf install -y memcached
# Allow connections from all interfaces
sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/sysconfig/memcached
sudo systemctl enable --now memcached
sudo firewall-cmd --add-port=11211/tcp --permanent && sudo firewall-cmd --reload
```

### rmq01 — RabbitMQ

```bash
vagrant ssh rmq01

sudo dnf install -y centos-release-rabbitmq-38
sudo dnf --enablerepo=centos-rabbitmq-38 install -y rabbitmq-server
sudo systemctl enable --now rabbitmq-server

# Disable loopback restriction
sudo sh -c 'echo "[{rabbit, [{loopback_users, []}]}]." > /etc/rabbitmq/rabbitmq.config'
sudo rabbitmqctl add_user edustack edustack@2026
sudo rabbitmqctl set_user_tags edustack administrator
sudo rabbitmqctl set_permissions -p / edustack ".*" ".*" ".*"
sudo systemctl restart rabbitmq-server
sudo firewall-cmd --add-port=5672/tcp --permanent && sudo firewall-cmd --reload
```

### app01 — Apache Tomcat

```bash
vagrant ssh app01

# Install Java 17 and Maven
sudo dnf install -y java-17-openjdk java-17-openjdk-devel maven git wget

# Download and install Tomcat 10
cd /tmp && wget https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.26/bin/apache-tomcat-10.1.26.tar.gz
tar xzf apache-tomcat-10.1.26.tar.gz
sudo useradd --home-dir /usr/local/tomcat --shell /sbin/nologin tomcat
sudo cp -r apache-tomcat-10.1.26/* /usr/local/tomcat/
sudo chown -R tomcat:tomcat /usr/local/tomcat

# Build and deploy the application
git clone https://github.com/Reich-imperial/edustack.git /tmp/edustack
cd /tmp/edustack && mvn install
sudo cp target/EduStack.war /usr/local/tomcat/webapps/ROOT.war

# Create systemd service (see vagrant/Automated_Provisioning/tomcat.sh for full service file)
sudo systemctl enable --now tomcat
sudo firewall-cmd --add-port=8080/tcp --permanent && sudo firewall-cmd --reload
```

### web01 — Nginx

```bash
vagrant ssh web01

sudo apt update && sudo apt install -y nginx

# Write reverse proxy config
sudo tee /etc/nginx/sites-available/edustack > /dev/null <<'EOF'
upstream eduapp { server app01:8080; }
server {
    listen 80;
    location / {
        proxy_pass http://eduapp;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/edustack /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
```

---

## CI/CD Pipeline

The `main` branch runs a full DevSecOps pipeline on every push:

```
git push → GitHub Actions
              │
              ├── 1. GitLeaks       — scan all commits for leaked secrets
              ├── 2. Snyk           — scan Maven dependencies for CVEs
              ├── 3. Maven Build    — compile, test, package WAR
              ├── 4. Docker Build   — build container image
              ├── 5. Trivy          — scan container image for CVEs
              ├── 6. Push to ECR    — store image in Amazon ECR (OIDC auth)
              └── 7. Deploy to EC2  — SSH, pull image, restart container
```

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `SNYK_TOKEN` | From snyk.io → Account Settings |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `EC2_HOST` | Public IP of your EC2 instance |
| `EC2_SSH_KEY` | Contents of your `.pem` key file |
| `DB_HOST` | Private IP of your database server |
| `DB_PASS` | Database password |
| `RMQ_HOST` | RabbitMQ server IP |
| `MC_HOST` | Memcached server IP |

---

## Database Schema

```
┌──────────────┐     ┌──────────────────┐     ┌────────────────┐
│   users      │     │   enrolments     │     │   courses      │
│──────────────│     │──────────────────│     │────────────────│
│ id (PK)      │────►│ student_id (FK)  │◄────│ id (PK)        │
│ username     │     │ course_id (FK)   │     │ code           │
│ email        │     │ session          │     │ title          │
│ role         │     └──────────────────┘     │ department     │
│ department   │                              │ lecturer_id    │
└──────┬───────┘                              └────────────────┘
       │
       │     ┌──────────────────┐     ┌────────────────────┐
       │     │   grades         │     │   announcements    │
       └────►│──────────────────│     │────────────────────│
             │ student_id (FK)  │     │ id (PK)            │
             │ course_id (FK)   │     │ title              │
             │ score            │     │ body               │
             │ grade            │     │ author_id (FK)     │
             └──────────────────┘     └────────────────────┘
```
> **Important:** The Java application was written for the original vprofile
> schema in `db_backup.sql`. The custom EduStack schema in `db_setup.sql`
> is included for reference and future development but the app currently
> runs on `db_backup.sql`.
---

## Project Structure

```
edustack/
├── .github/
│   └── workflows/
│       └── pipeline.yml          # CI/CD pipeline
├── Docker-files/
│   ├── app/
│   │   └── Dockerfile            # Multi-stage Tomcat build
│   ├── db/
│   │   └── Dockerfile            # MySQL with schema pre-loaded
│   └── web/
│       ├── Dockerfile            # Nginx image
│       └── edustack.conf         # Nginx reverse proxy config
├── kubernetes/
│   └── edustack-k8s.yml          # Full K8s manifests + HPA
├── src/
│   └── main/
│       └── resources/
│           ├── application.properties   # Backend service config
│           └── db_setup.sql             # Schema + seed data
├── vagrant/
│   ├── Manual_Provisioning/
│   │   └── Vagrantfile           # 5 VMs, manual setup
│   └── Automated_Provisioning/
│       ├── Vagrantfile           # 5 VMs, auto-provisioned
│       ├── mysql.sh
│       ├── memcache.sh
│       ├── rabbitmq.sh
│       ├── tomcat.sh
│       └── nginx.sh
├── docker-compose.yml            # Full stack via Docker Compose
└── README.md
```

---

## Tech Stack

| Category | Technology | Version |
|----------|-----------|---------|
| Web server | Nginx | 1.25 |
| App server | Apache Tomcat | 10.1 |
| Language | Java | 17 |
| Build tool | Maven | 3.8+ |
| Database | MariaDB / MySQL | 10.6 / 8.0 |
| Cache | Memcached | 1.6 |
| Message broker | RabbitMQ | 3.12 |
| VM automation | Vagrant + VirtualBox | 2.3+ / 7.0+ |
| Containers | Docker + Compose | 24+ |
| Orchestration | Kubernetes | 1.28+ |
| CI/CD | GitHub Actions | — |
| Registry | Amazon ECR | — |
| Cloud | AWS (EC2, S3, IAM) | — |
| Security scanning | Snyk + Trivy + GitLeaks | — |
| IaC | Terraform (coming) | — |

---

## Troubleshooting

### Maven build fails with "Java heap space"
Maven runs out of memory on VMs with limited RAM. Fix it before building:
```bash
export MAVEN_OPTS="-Xmx512m -Xms256m"
mvn install -DskipTests
```

### Permission denied on target/ folder
A previous failed build left files owned by root. Fix ownership first:
```bash
sudo chown -R vagrant:vagrant /tmp/edustack
```
Then run Maven again.

### Tomcat starts but app returns 404
The WAR deployed but ROOT folder wasn't replaced. Run:
```bash
sudo systemctl stop tomcat
sudo rm -rf /usr/local/tomcat/webapps/ROOT
sudo systemctl start tomcat
```

### "Could not resolve placeholder 'elasticsearch.host'"
The application.properties is missing Elasticsearch config. Add it:
```bash
sudo su
cat >> /usr/local/tomcat/webapps/ROOT/WEB-INF/classes/application.properties << 'EOF'

#Elasticsearch Configuration
elasticsearch.host=localhost
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode
EOF
sudo systemctl restart tomcat
```

### Login returns "user not found"
The app uses the original vprofile database schema. Make sure
db_backup.sql is loaded, not db_setup.sql:
```bash
# On db01
sudo mysql -u root -peduAdmin@2026 -e \
  'DROP DATABASE edustack; CREATE DATABASE edustack;'
sudo mysql -u root -peduAdmin@2026 edustack < /tmp/db_backup.sql
```
Then restart Tomcat on app01.

### Memcached shows inactive in health check
Restart it manually:
```bash
vagrant ssh mc01 -c "sudo systemctl restart memcached"
```     
```

---

## Skills Demonstrated

Building EduStack covers the following DevOps competencies:

- Linux server administration (CentOS + Ubuntu)
- Bash scripting for automated service provisioning
- Vagrant multi-VM orchestration
- Java application deployment (Maven + Tomcat)
- MySQL database design and administration
- Distributed caching with Memcached
- Message queuing with RabbitMQ
- Docker containerisation and multi-stage builds
- Docker Compose multi-service orchestration
- Kubernetes deployments, services, and HPA
- GitHub Actions CI/CD pipeline design
- DevSecOps: GitLeaks, Snyk, Trivy integration
- AWS: EC2, ECR, IAM OIDC, Security Groups
- Infrastructure as Code principles

---

## Author

**Samson Olanipekun**
Cloud & DevOps Engineer | Building in public from  Nigeria

- GitHub: [github.com/Reich-imperial](https://github.com/Reich-imperial)
- LinkedIn: [linkedin.com/in/samson-olanipekun](https://linkedin.com/in/samson-olanipekun-devops)
- Open to: Remote DevOps internships and junior roles

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

*EduStack is a personal project built to demonstrate DevOps skills. It is a personalised reimplementation of the multi-tier architecture concept taught in the Decoding DevOps course by Imran Teli.*
# Pipeline test

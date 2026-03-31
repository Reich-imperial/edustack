# EduStack — AWS Lift-and-Shift

Migrates EduStack from local Vagrant VMs to 5 AWS EC2 instances.

## Architecture

```
Internet
    ↓ HTTP :80
web01 — Nginx (PUBLIC subnet — t2.micro)
    ↓ :8080 (from web-sg only)
app01 — Tomcat (PRIVATE subnet — t2.micro)
    ↓ :3306        ↓ :11211      ↓ :5672
db01 — MySQL    mc01 — Memcached  rmq01 — RabbitMQ
(PRIVATE)       (PRIVATE)         (PRIVATE)
```

## Key design decisions

- All t2.micro — free tier eligible
- WAR built locally with Maven, uploaded to S3, downloaded by EC2
- No Maven on any EC2 instance — keeps memory footprint small
- IAM role gives EC2 read access to S3 — no hardcoded credentials
- Security groups chained — each service only accepts traffic from the layer above it
- All provisioning via user data scripts — fully automated, zero manual SSH

## How to run

```bash
# Step 1: Set up this branch (run once)
bash aws/setup-branch.sh

# Step 2: Build and deploy to AWS
bash aws/build-edustack-aws.sh

# Step 3: Check all services are healthy (after 15 mins)
bash aws/health-check.sh

# Step 4: Clean up when done
bash aws/cleanup-edustack-aws.sh
```

## Cost

All t2.micro instances at ~$0.0116/hour each.
5 instances × $0.0116 = ~$0.058/hour total (~₦90/hour).
Run for 2 hours to test, clean up — total cost under ₦200.

## Credentials (vprofile defaults)

- App login: admin_vp / admin_vp
- MySQL: admin / admin123
- RabbitMQ: test / test

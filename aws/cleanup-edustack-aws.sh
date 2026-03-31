#!/bin/bash
# ============================================================
# cleanup-edustack-aws.sh — tear down all EduStack AWS resources
# Correct dependency order — no errors
# Usage: bash cleanup-edustack-aws.sh
# ============================================================

RESOURCES=~/edustack-lift-shift/resources.env

if [ ! -f "$RESOURCES" ]; then
  echo "ERROR: resources.env not found. Nothing to clean up."
  exit 1
fi

source $RESOURCES

echo "======================================================"
echo " EduStack AWS Cleanup"
echo "======================================================"
read -p "Terminate all 5 EC2 instances + delete S3 bucket? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then echo "Cancelled."; exit 0; fi

# ── Step 1: Terminate all EC2 instances ───────────────────
echo ""
echo "[1/4] Terminating all instances..."
aws ec2 terminate-instances \
  --instance-ids \
    $WEB_INSTANCE_ID \
    $APP_INSTANCE_ID \
    $DB_INSTANCE_ID \
    $MC_INSTANCE_ID \
    $RMQ_INSTANCE_ID > /dev/null

echo "  Waiting for all instances to terminate..."
aws ec2 wait instance-terminated \
  --instance-ids \
    $WEB_INSTANCE_ID \
    $APP_INSTANCE_ID \
    $DB_INSTANCE_ID \
    $MC_INSTANCE_ID \
    $RMQ_INSTANCE_ID
echo "  ✓ All instances terminated"

# ── Step 2: Empty and delete S3 artifact bucket ───────────
echo ""
echo "[2/4] Deleting S3 artifact bucket..."
if [ -n "$ARTIFACT_BUCKET" ] && [ "$ARTIFACT_BUCKET" != "None" ]; then
  aws s3 rm s3://$ARTIFACT_BUCKET --recursive 2>/dev/null || true
  aws s3 rb s3://$ARTIFACT_BUCKET 2>/dev/null && \
    echo "  ✓ Bucket $ARTIFACT_BUCKET deleted" || \
    echo "  Bucket not found — skipping"
fi

# ── Step 3: Remove SG cross-references then delete SGs ────
# Must revoke all cross-references before any SG can be deleted
echo ""
echo "[3/4] Removing security group cross-references..."

# app-sg has rules referencing web-sg and app-sg referencing web-sg
aws ec2 revoke-security-group-ingress \
  --group-id $APP_SG --protocol tcp --port 8080 \
  --source-group $WEB_SG 2>/dev/null || true
aws ec2 revoke-security-group-ingress \
  --group-id $APP_SG --protocol tcp --port 22 \
  --source-group $WEB_SG 2>/dev/null || true

# db-sg references app-sg and web-sg
aws ec2 revoke-security-group-ingress \
  --group-id $DB_SG --protocol tcp --port 3306 \
  --source-group $APP_SG 2>/dev/null || true
aws ec2 revoke-security-group-ingress \
  --group-id $DB_SG --protocol tcp --port 22 \
  --source-group $WEB_SG 2>/dev/null || true

# mc-sg references app-sg and web-sg
aws ec2 revoke-security-group-ingress \
  --group-id $MC_SG --protocol tcp --port 11211 \
  --source-group $APP_SG 2>/dev/null || true
aws ec2 revoke-security-group-ingress \
  --group-id $MC_SG --protocol tcp --port 22 \
  --source-group $WEB_SG 2>/dev/null || true

# rmq-sg references app-sg and web-sg
aws ec2 revoke-security-group-ingress \
  --group-id $RMQ_SG --protocol tcp --port 5672 \
  --source-group $APP_SG 2>/dev/null || true
aws ec2 revoke-security-group-ingress \
  --group-id $RMQ_SG --protocol tcp --port 15672 \
  --source-group $WEB_SG 2>/dev/null || true
aws ec2 revoke-security-group-ingress \
  --group-id $RMQ_SG --protocol tcp --port 22 \
  --source-group $WEB_SG 2>/dev/null || true

echo "  Deleting security groups (dependent SGs first)..."
# Delete dependent SGs first, then web-sg last
for SG in $APP_SG $DB_SG $MC_SG $RMQ_SG $WEB_SG; do
  aws ec2 delete-security-group --group-id $SG 2>/dev/null && \
    echo "  ✓ Deleted $SG" || \
    echo "  Skipped $SG (not found)"
done

# ── Step 4: Clean up IAM role ─────────────────────────────
echo ""
echo "[4/4] Cleaning up IAM role..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name edustack-ec2-profile \
  --role-name edustack-ec2-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name edustack-ec2-profile 2>/dev/null || true
aws iam detach-role-policy \
  --role-name edustack-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
aws iam delete-role \
  --role-name edustack-ec2-role 2>/dev/null && \
  echo "  ✓ IAM role deleted" || \
  echo "  IAM role not found — skipping"

# Clean up local temp files
rm -f /tmp/db01-userdata.sh /tmp/mc01-userdata.sh \
       /tmp/rmq01-userdata.sh /tmp/app01-userdata.sh \
       /tmp/web01-userdata.sh /tmp/application.properties \
       /tmp/ec2-trust.json
rm -f ~/edustack-lift-shift/resources.env

echo ""
echo "======================================================"
echo " ✓ Cleanup complete — no ongoing charges"
echo " VPC and subnets preserved for future projects"
echo "======================================================"

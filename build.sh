#!/bin/bash
# AMI bake step (runs as root in Image Builder on AL2023):
# - install Docker + tooling
# - pre-pull Mattermost image
# - write a provision script that runs at every instance boot (idempotent
#   create of Aurora cluster + S3 bucket + env file)
# - write 3 systemd units (provision oneshot -> mattermost docker -> health)
# - enable services (instance starts them at boot)
set -eux

dnf install -y docker awscli jq python3
systemctl enable docker
systemctl start docker

# Pre-pull Mattermost image so boot doesn't have to.
MM_VERSION=9.5.0
docker pull mattermost/mattermost-team-edition:${MM_VERSION}

mkdir -p /etc/mattermost

# ---------- /usr/local/bin/mattermost-provision.sh ----------
# Idempotent: creates Aurora cluster + DB instance + S3 bucket on first boot
# (blocks ~15 min on db-instance-available). Subsequent boots see resources
# exist and just refresh /etc/mattermost/env (~30s).
cat > /usr/local/bin/mattermost-provision.sh <<'PROVISION'
#!/bin/bash
set -eux

CLUSTER_ID=mattermost-cluster
INSTANCE_ID=${CLUSTER_ID}-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
BUCKET=mattermost-files-${ACCOUNT_ID}-${REGION}

# Aurora cluster — idempotent
if ! aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$REGION" &>/dev/null; then
  MAC=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac)
  VPC_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id)
  ALL_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text --region "$REGION")
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text --region "$REGION")

  aws rds create-db-subnet-group --db-subnet-group-name "$CLUSTER_ID" \
    --db-subnet-group-description mattermost --subnet-ids $ALL_SUBNETS --region "$REGION"

  SG_ID=$(aws ec2 create-security-group --group-name "${CLUSTER_ID}-sg" \
    --description mattermost --vpc-id "$VPC_ID" \
    --query GroupId --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 5432 --cidr "$VPC_CIDR" --region "$REGION"

  aws rds create-db-cluster --db-cluster-identifier "$CLUSTER_ID" \
    --engine aurora-postgresql --engine-version 15.4 \
    --database-name mattermost --master-username mattermost \
    --manage-master-user-password \
    --db-subnet-group-name "$CLUSTER_ID" \
    --vpc-security-group-ids "$SG_ID" \
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
    --storage-encrypted --region "$REGION"

  aws rds create-db-instance --db-instance-identifier "$INSTANCE_ID" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --db-instance-class db.serverless \
    --engine aurora-postgresql --region "$REGION"

  aws rds wait db-instance-available --db-instance-identifier "$INSTANCE_ID" --region "$REGION"
fi

# S3 bucket — idempotent
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" &>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
fi

# Read Aurora-managed secret, write Mattermost env file
ENDPOINT=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text --region "$REGION")
SECRET_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text --region "$REGION")
SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --region "$REGION" --query SecretString --output text)
DB_USER=$(echo "$SECRET" | jq -r .username)
DB_PASS=$(echo "$SECRET" | jq -r .password)

cat > /etc/mattermost/env <<EOF
MM_SQLSETTINGS_DRIVERNAME=postgres
MM_SQLSETTINGS_DATASOURCE=postgres://${DB_USER}:${DB_PASS}@${ENDPOINT}:5432/mattermost?sslmode=require
MM_FILESETTINGS_DRIVERNAME=amazons3
MM_FILESETTINGS_AMAZONS3BUCKET=${BUCKET}
MM_FILESETTINGS_AMAZONS3REGION=${REGION}
MM_FILESETTINGS_AMAZONS3SSL=true
MM_FILESETTINGS_AMAZONS3SIGNV4=true
EOF
chmod 600 /etc/mattermost/env
PROVISION
chmod +x /usr/local/bin/mattermost-provision.sh

# ---------- systemd: provision (oneshot) ----------
cat > /etc/systemd/system/mattermost-provision.service <<'UNIT'
[Unit]
Description=Provision Aurora/S3 + write Mattermost env file
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
Before=mattermost.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mattermost-provision.sh
RemainAfterExit=true
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT

# ---------- systemd: mattermost (docker run) ----------
cat > /etc/systemd/system/mattermost.service <<'UNIT'
[Unit]
Description=Mattermost (docker)
Requires=docker.service mattermost-provision.service
After=docker.service mattermost-provision.service

[Service]
ExecStartPre=-/usr/bin/docker rm -f mattermost
ExecStart=/usr/bin/docker run --name mattermost \
  -p 80:8065 \
  --env-file /etc/mattermost/env \
  mattermost/mattermost-team-edition:9.5.0
ExecStop=/usr/bin/docker stop mattermost
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

# ---------- systemd: health responder on :8081 ----------
# Only starts AFTER mattermost.service is active so that ALB doesn't mark
# the target healthy and route traffic to :80 before Mattermost is listening.
mkdir -p /srv/health
echo ok > /srv/health/index.html
cat > /etc/systemd/system/health.service <<'UNIT'
[Unit]
Description=Health responder on :8081 (gates ALB traffic to :80)
Requires=mattermost.service
After=mattermost.service

[Service]
ExecStart=/usr/bin/python3 -m http.server 8081 --directory /srv/health
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mattermost-provision.service mattermost.service health.service

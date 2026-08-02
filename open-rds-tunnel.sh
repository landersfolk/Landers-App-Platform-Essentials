#!/bin/bash
#
# open-rds-tunnel.sh
# Opens an AWS SSM port-forwarding tunnel from localhost:5432
# through the EC2 bastion (landers-qa) to the private RDS instance.
#
# Usage:
#   ./open-rds-tunnel.sh
#
# Once running, keep this terminal open and connect your
# PostgreSQL client (DBeaver, pgAdmin, etc.) to:
#   Host: localhost
#   Port: 5432
#
# Press Ctrl+C to close the tunnel when done.

set -e

# ---- Config: edit these if they ever change ----
INSTANCE_ID="i-0285595f45e8d9f7d"
RDS_ENDPOINT="landers-db.c52kk2mayopg.eu-west-1.rds.amazonaws.com"
REMOTE_PORT="5432"
LOCAL_PORT="5432"
AWS_REGION="eu-west-1"
# --------------------------------------------------

echo "Opening SSM tunnel..."
echo "  EC2 instance: $INSTANCE_ID"
echo "  RDS endpoint: $RDS_ENDPOINT"
echo "  Local port:   localhost:$LOCAL_PORT"
echo ""

aws ssm start-session \
  --region "$AWS_REGION" \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_ENDPOINT\"],\"portNumber\":[\"$REMOTE_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"

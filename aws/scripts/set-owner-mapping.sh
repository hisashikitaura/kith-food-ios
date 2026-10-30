#!/usr/bin/env bash
# Fallback: (re)write the Cognito sub -> Firebase uid mapping for the owner from config.local.json.
# Usage: ./scripts/set-owner-mapping.sh   (uses --profile kith)
set -euo pipefail
cd "$(dirname "$0")/.."
POOL=$(aws cloudformation describe-stacks --stack-name KithFood --profile kith --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
TABLE=$(aws cloudformation describe-stacks --stack-name KithFood --profile kith --query "Stacks[0].Outputs[?OutputKey=='TableName'].OutputValue" --output text)
EMAIL=$(node -p "require('./config.local.json').ownerEmail.toLowerCase()")
UID_=$(node -p "require('./config.local.json').ownerFirebaseUid")
SUB=$(aws cognito-idp list-users --user-pool-id "$POOL" --profile kith --filter "email = \"$EMAIL\"" --query 'Users[0].Attributes[?Name==`sub`].Value' --output text)
[ -n "$SUB" ] && [ "$SUB" != "None" ] || { echo "owner not signed in yet"; exit 1; }
aws dynamodb put-item --table-name "$TABLE" --profile kith --item "{\"PK\":{\"S\":\"IDMAP#$SUB\"},\"SK\":{\"S\":\"IDMAP\"},\"firebaseUid\":{\"S\":\"$UID_\"},\"email\":{\"S\":\"$EMAIL\"}}"
echo "mapped $SUB -> $UID_"

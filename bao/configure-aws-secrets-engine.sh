#!/usr/bin/env bash
# Configure OpenBao AWS secrets engine for ExternalDNS
# Uses existing OpenBao AWS credentials to assume roles
# and issue short-lived temporary credentials.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://keeper.goodmanners.services}"
export BAO_ADDR

ROLE_ARN="${1:?usage: $0 <iam-role-arn>}"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${BAO_TOKEN:-${VAULT_TOKEN:-}}" ]] || die "not logged in to OpenBao"

echo "Configuring AWS secrets engine for role: $ROLE_ARN"

# Enable AWS secrets engine (idempotent)
if ! bao secrets list -format=json 2>/dev/null | grep -q '"aws"'; then
  echo "  Enabling AWS secrets engine..."
  bao secrets enable -path=aws aws
else
  echo "  AWS secrets engine already enabled"
fi

# Configure AWS credentials (uses env vars already set in compose)
echo "  Configuring AWS credentials..."
bao write aws/config \
  region="${AWS_REGION:-us-east-1}" \
  access_key="${AWS_ACCESS_KEY_ID:-}" \
  secret_key="${AWS_SECRET_ACCESS_KEY:-}" \
  -format=json > /dev/null

# Create role for ExternalDNS
echo "  Creating role 'external-dns'..."
bao write aws/role/external-dns \
  role_arn="$ROLE_ARN" \
  credential_type="assumed_role" \
  ttl="1h" \
  max_ttl="12h"

echo ""
echo "Done. Temporary credentials available at: secret/aws/creds/external-dns"
echo "TTL: 1h (max 12h)"

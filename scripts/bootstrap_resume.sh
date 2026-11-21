#!/usr/bin/env bash
# Resume / complete the terraform/bootstrap deployment safely, one gated step at a time.
#
#   scripts/bootstrap_resume.sh            # run from the repository root
#
# Steps (stops at the first problem; every step is safe to re-run):
#   1. Verify AWS identity is the expected account (read-only)
#   2. Back up local state; refuse to continue if terraform/bootstrap/backend.tf exists
#      before the bucket does (that is the "Backend initialization required" trap)
#   3. Fresh plan; abort if it contains ANY change/destroy/replace
#   4. Ask you to type "apply"; apply exactly that plan; full output -> bootstrap-apply.log
#   5. Verify bucket: versioning, AES256, public-access block, policy statements (read-only)
#   6. Ask you to type "migrate"; move state into S3; verify 18 resources + encrypted object
#
# Credentials: the AWS CLI profile's short-lived credentials are exported only into this
# script's process (never printed, never written to disk). Terraform's AWS provider cannot
# read every CLI profile type, which is why we export them.
set -euo pipefail

EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-666102401492}"
PROFILE="${AWS_PROFILE:-aiops-dev}"
REGION="${AWS_REGION:-us-east-1}"
TF_DIR="terraform/bootstrap"
BUCKET="aiops-tfstate-${EXPECTED_ACCOUNT}-${REGION}"
EXPECTED_TOTAL=18
LOG="bootstrap-apply.log"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   OK  %s\n' "$*"; }
fail() { printf '\n   STOP  %s\n' "$*" >&2; exit 1; }
tf()   { terraform -chdir="$TF_DIR" "$@"; }
managed_count() {
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(len([r for r in d.get('resources',[]) if r['mode']=='managed']))" "$1"
}

[ -d "$TF_DIR" ] || fail "run this from the repository root (cannot find $TF_DIR)"
command -v terraform >/dev/null || fail "terraform not found"
command -v aws >/dev/null || fail "aws CLI not found"

# --- 1. identity -------------------------------------------------------------------------
say "1/6  AWS identity (profile: $PROFILE)"
creds="$(aws configure export-credentials --profile "$PROFILE" --format env 2>/dev/null)" \
  || fail "cannot get credentials for profile '$PROFILE'. Run: aws sso login --profile $PROFILE  (or: aws login --profile $PROFILE)"
eval "$creds"
unset creds AWS_PROFILE
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
account="$(aws sts get-caller-identity --query Account --output text)" || fail "credentials rejected by AWS (expired?). Sign in again and re-run."
[ "$account" = "$EXPECTED_ACCOUNT" ] || fail "signed in to account $account, expected $EXPECTED_ACCOUNT"
ok "account $account, region $REGION"

# --- 2. local state + backend safety -----------------------------------------------------
say "2/6  Local state and backend file"
bucket_exists=false
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then bucket_exists=true; fi

# backend.tf must be set aside while state is still local (or the bucket does not exist yet);
# otherwise every terraform command stops with "Backend initialization required".
if [ -f "$TF_DIR/backend.tf" ] && { [ "$bucket_exists" = false ] || [ -f "$TF_DIR/terraform.tfstate" ]; }; then
  mv "$TF_DIR/backend.tf" "$TF_DIR/backend.tf.pending"
  ok "moved backend.tf -> backend.tf.pending (state is still local; restored in step 6)"
fi

if [ -f "$TF_DIR/terraform.tfstate" ]; then
  backup="$HOME/bootstrap-tfstate-backup-$(date +%Y%m%d-%H%M%S).json"
  cp "$TF_DIR/terraform.tfstate" "$backup"
  ok "local state backed up to $backup ($(managed_count "$TF_DIR/terraform.tfstate") managed resources)"
elif [ "$bucket_exists" = true ] && [ -f "$TF_DIR/backend.tf" ]; then
  ok "no local state; backend.tf present and bucket exists (state may already be in S3)"
else
  ok "no local state yet (fresh bootstrap)"
fi

if [ "$bucket_exists" = true ] && [ -f "$TF_DIR/backend.tf" ] && [ ! -f "$TF_DIR/terraform.tfstate" ]; then
  say "Bucket and backend already in place - verifying only"
  tf init -input=false >/dev/null
  n="$(tf state list | grep -vc '^data\.' || true)"
  [ "$n" = "$EXPECTED_TOTAL" ] && ok "remote state has $n managed resources - bootstrap already complete" && exit 0
  fail "remote state has $n managed resources (expected $EXPECTED_TOTAL) - send this output for review"
fi

# --- 3. plan -----------------------------------------------------------------------------
say "3/6  Fresh plan (read-only)"
[ -f "$TF_DIR/terraform.tfvars" ] || fail "missing $TF_DIR/terraform.tfvars (copy terraform.tfvars.example and set budget_email)"
grep -q 'you@example.com' "$TF_DIR/terraform.tfvars" && fail "budget_email in terraform.tfvars is still the placeholder"
tf init -input=false >/dev/null
tf plan -input=false -no-color -out=bootstrap.tfplan > bootstrap-plan.log 2>&1 || { tail -30 bootstrap-plan.log; fail "plan failed (full output: bootstrap-plan.log)"; }
summary="$(grep -E '^Plan:|No changes' bootstrap-plan.log || true)"
grep -E '# .* will be created' bootstrap-plan.log | sed 's/^ *# /   + /'
echo "   $summary"
if grep -qE '# .* (will be updated|will be destroyed|must be replaced|will be read during apply)' bootstrap-plan.log \
   || ! grep -qE 'Plan: [0-9]+ to add, 0 to change, 0 to destroy|No changes' bootstrap-plan.log; then
  fail "plan contains changes other than additions - not applying. Send bootstrap-plan.log for review."
fi

# --- 4. apply ----------------------------------------------------------------------------
if grep -q 'No changes' bootstrap-plan.log; then
  ok "nothing to create"
else
  say "4/6  Apply"
  printf '   This creates the resources listed above in account %s (about %s/month).\n' "$account" "USD 0.01"
  read -r -p "   Type 'apply' to continue, anything else to stop: " answer
  [ "$answer" = "apply" ] || fail "stopped by you before apply (nothing created)"
  if ! tf apply -input=false -no-color bootstrap.tfplan 2>&1 | tee "$LOG"; then
    grep -A12 'Error:' "$LOG" | head -50 >&2 || true
    fail "apply failed - nothing is destroyed; send the Error lines above (full log: $LOG)"
  fi
  grep -q 'Apply complete' "$LOG" || fail "apply did not report completion (see $LOG)"
fi

# --- 5. verify bucket --------------------------------------------------------------------
say "5/6  Verify state bucket security (read-only)"
[ "$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)" = "Enabled" ] || fail "versioning not Enabled"
ok "versioning Enabled"
[ "$(aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" = "AES256" ] || fail "default encryption is not AES256"
ok "default encryption AES256"
pab="$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)"
[ "$(echo "$pab" | tr -s '\t ' '\n' | grep -c True)" = 4 ] || fail "public access block not fully enabled: $pab"
ok "public access block: all 4 enabled"
aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text | python3 -c '
import json, sys
p = json.load(sys.stdin)
got = {s["Sid"]: sorted(s.get("Condition", {})) for s in p["Statement"]}
want = {"DenyInsecureTransport": ["Bool"],
        "DenyExplicitNonAES256Encryption": ["Null", "StringNotEquals"],
        "DenySSECustomerKeys": ["Null"]}
bad = [k for k in got for op in got[k] if op.endswith("IfExists")]
if got != want or bad:
    sys.exit(f"   unexpected bucket policy: {got}")
print("   OK  bucket policy: 3 conditional Deny statements, no IfExists")
' || fail "bucket policy does not match the reviewed design"

# --- 6. migrate state --------------------------------------------------------------------
say "6/6  Move bootstrap state into S3"
if [ ! -f "$TF_DIR/backend.tf" ]; then
  if [ -f "$TF_DIR/backend.tf.pending" ]; then mv "$TF_DIR/backend.tf.pending" "$TF_DIR/backend.tf"
  else sed "s/aiops-tfstate-<account-id>-us-east-1/$BUCKET/" "$TF_DIR/backend.tf.example" > "$TF_DIR/backend.tf"; fi
fi
grep -q "bucket *= *\"$BUCKET\"" "$TF_DIR/backend.tf" || fail "backend.tf does not point at $BUCKET"
ok "backend.tf -> s3://$BUCKET/bootstrap/terraform.tfstate"
read -r -p "   Type 'migrate' to copy local state into S3, anything else to stop: " answer
[ "$answer" = "migrate" ] || fail "stopped by you before migration (resources exist; state is still local and backed up)"
tf init -input=false -migrate-state -force-copy
n="$(tf state list | grep -vc '^data\.' || true)"
[ "$n" = "$EXPECTED_TOTAL" ] || fail "state in S3 has $n managed resources, expected $EXPECTED_TOTAL"
ok "state in S3 has $n managed resources"
enc="$(aws s3api head-object --bucket "$BUCKET" --key bootstrap/terraform.tfstate --query ServerSideEncryption --output text)"
[ "$enc" = "AES256" ] || fail "state object encryption is '$enc', expected AES256"
ok "state object encrypted with AES256 (the bucket policy allowed the backend's write)"

say "Bootstrap complete"
tf output github_repository_variables
echo
echo "   Next: GitHub repository variables (values above), protected 'aws-dev' environment, default branch = main."
echo "   Nothing billable has been created. envs/dev needs its own plan and your approval."

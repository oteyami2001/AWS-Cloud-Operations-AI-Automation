# Terraform remote state. Locking uses S3 native lock files (`use_lockfile = true`, Terraform >= 1.10),
# which replaces the deprecated DynamoDB lock table.
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is unnecessary for a single-region demo; versioning protects history.
  # checkov:skip=CKV_AWS_18:Server access logging omitted for cost; CloudTrail management events record bucket API calls.
  # checkov:skip=CKV2_AWS_62:Event notifications are not needed for a state bucket.
  # checkov:skip=CKV_AWS_145:SSE-S3 (AES-256). State holds no secrets (fault token is write-only/ephemeral); avoids a $1/month KMS key.
  bucket = "${var.project}-tfstate-${local.account}-${var.region}"
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AWS-0132 SSE-S3 by design: state contains no secrets (write-only token); see checkov CKV_AWS_145 note.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# State-bucket policy. Single source of truth in policies/state_bucket_policy.json.tftpl, also read
# by tests/unit/test_state_bucket_policy.py, which evaluates it with AWS IAM condition semantics
# against the exact requests the Terraform S3 backend makes.
#
# IAM semantics that matter here (AWS IAM User Guide, "...IfExists condition operators"):
#   StringNotEqualsIfExists evaluates to TRUE when the key is ABSENT, so a Deny using it rejects every
#   upload WITHOUT an encryption header: default-encrypted uploads, multipart UploadPart requests,
#   and backend writes with `encrypt` unset. The policy therefore denies only when the header IS
#   present (Null = "false") AND is not AES256. Header-less uploads are still encrypted with AES-256
#   by the bucket default encryption (aws_s3_bucket_server_side_encryption_configuration.state).

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = templatefile("${path.module}/policies/state_bucket_policy.json.tftpl", { bucket_arn = aws_s3_bucket.state.arn })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

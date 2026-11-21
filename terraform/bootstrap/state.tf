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

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Blocks uploads that REQUEST a different server-side encryption (e.g. SSE-KMS with an arbitrary
  # key). Uploads without the header are allowed and still encrypted with AES-256 by the bucket's
  # default encryption; the Terraform S3 backend (`encrypt = true`) sends "AES256" explicitly.
  # !! The condition is load-bearing: without it this statement denies EVERY PutObject, so
  # Terraform could never write state or its lock file. Guarded by tests/bootstrap.tftest.hcl.
  statement {
    sid       = "DenyNonAES256ObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

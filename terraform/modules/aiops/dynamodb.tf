# Incident records. Keys/GSIs must match src/aiops/store.py and tests/conftest.py.
resource "aws_dynamodb_table" "incidents" {
  name         = "${var.name_prefix}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }
  attribute {
    name = "dedupe_key"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "S"
  }
  attribute {
    name = "execution_id"
    type = "S"
  }

  global_secondary_index {
    name            = "by_dedupe_key"
    hash_key        = "dedupe_key"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "by_execution_id"
    hash_key        = "execution_id"
    projection_type = "ALL"
  }

  # Only the Bedrock quota counters carry expires_at; incident history is kept.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = false # demo must be destroyable; enable in production
}

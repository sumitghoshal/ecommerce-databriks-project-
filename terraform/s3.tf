locals {
  raw_bucket_name       = "${var.project_name}-raw-zone-${var.bucket_suffix}"
  processed_bucket_name = "${var.project_name}-processed-zone-${var.bucket_suffix}"
  curated_bucket_name   = "${var.project_name}-curated-zone-${var.bucket_suffix}"
}

resource "aws_s3_bucket" "raw" {
  bucket = local.raw_bucket_name
  tags   = { Zone = "raw" }
}

resource "aws_s3_bucket" "processed" {
  bucket = local.processed_bucket_name
  tags   = { Zone = "processed" }
}

resource "aws_s3_bucket" "curated" {
  bucket = local.curated_bucket_name
  tags   = { Zone = "curated" }
}

# --- Encryption at rest (KMS for curated, AES256 for the rest) --------------
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "curated" {
  bucket = aws_s3_bucket.curated.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

# --- Block all public access ------------------------------------------------
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "curated" {
  bucket                  = aws_s3_bucket.curated.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Versioning on curated (protects analytics outputs) ---------------------
resource "aws_s3_bucket_versioning" "curated" {
  bucket = aws_s3_bucket.curated.id
  versioning_configuration { status = "Enabled" }
}

# --- Lifecycle: expire raw data after 90 days to control cost ---------------
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "expire-raw-after-90-days"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

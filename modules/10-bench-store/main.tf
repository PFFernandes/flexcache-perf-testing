# Test bench package bucket: one S3 bucket in one region.
#
# Holds only the vendor packages the clients install (vendor/), because the clients have no
# internet, only the S3 gateway endpoint of their own region. No results: those go to the
# results volume (modules/12-bench-results-volume).
#
# Called by stacks/00-bench-store once per region in use.
#
# Resources:
#   aws_s3_bucket.this (+ versioning, encryption, public access block, ownership, lifecycle)
#
# Tags: Name = the bucket name, plus the Creator tag from the provider default_tags.

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  # Terraform doesn't delete a bucket with packages in it: `destroy` fails with
  # BucketNotEmpty. Empty it first (aws s3 rm --recursive) if you want it gone.
  force_destroy = false

  tags = { Name = var.bucket_name }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "tidy-versions-and-uploads"
    status = "Enabled"
    filter {}

    # Overwritten or deleted objects stay recoverable for a while, then go.
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

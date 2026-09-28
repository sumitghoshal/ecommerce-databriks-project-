#!/bin/bash
# ===========================================================================
# Creates the S3 bucket + DynamoDB table that hold Terraform's own state.
# Terraform cannot create its own backend, so this runs FIRST, by hand.
#
# Usage: ./bootstrap_backend.sh my-unique-suffix ap-south-1
# ===========================================================================
set -euo pipefail

SUFFIX="${1:?Usage: $0 <unique-suffix> [region]}"
REGION="${2:-ap-south-1}"
BUCKET="ecommerce-devops-tfstate-${SUFFIX}"
TABLE="ecommerce-devops-tflock"

echo "Creating state bucket: ${BUCKET} in ${REGION}"

if [ "$REGION" = "ap-south-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "Creating lock table: ${TABLE}"
aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" 2>/dev/null || echo "  (table already exists)"

cat <<NOTE

Done. Now update terraform/versions.tf backend block to:

  backend "s3" {
    bucket         = "${BUCKET}"
    key            = "global/terraform.tfstate"
    region         = "${REGION}"
    dynamodb_table = "${TABLE}"
    encrypt        = true
  }

Then run:  cd terraform && terraform init
NOTE

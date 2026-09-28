#!/bin/bash
# ===========================================================================
# Runs the DATA pipeline end to end in the correct order.
#
# Order matters: the curated crawler must run AFTER the ETL job, because it
# catalogs that job's output.
#
# Usage: ./run_pipeline.sh [aws-region]
# ===========================================================================
set -euo pipefail

REGION="${1:-ap-south-1}"
PROJECT="ecommerce-devops"

cd "$(dirname "$0")/.."

RAW_BUCKET=$(terraform -chdir=terraform output -raw raw_bucket)
JOB_NAME=$(terraform -chdir=terraform output -raw glue_job_name)
RAW_CRAWLER=$(terraform -chdir=terraform output -raw glue_raw_crawler)
CURATED_CRAWLER=$(terraform -chdir=terraform output -raw glue_curated_crawler)

wait_for_crawler() {
    local name="$1"
    echo "    waiting for crawler ${name}…"
    while true; do
        state=$(aws glue get-crawler --name "$name" --region "$REGION" \
                --query 'Crawler.State' --output text)
        [ "$state" = "READY" ] && break
        sleep 15
    done
}

echo "==> 1/5 Generating and uploading sample batch data"
python3 scripts/generate_sample_data.py --rows 5000 --out ./data --upload "s3://${RAW_BUCKET}"

echo "==> 2/5 Running raw crawler"
aws glue start-crawler --name "$RAW_CRAWLER" --region "$REGION" 2>/dev/null || true
wait_for_crawler "$RAW_CRAWLER"

echo "==> 3/5 Running Glue ETL job"
RUN_ID=$(aws glue start-job-run --job-name "$JOB_NAME" --region "$REGION" \
         --query JobRunId --output text)
echo "    job run: ${RUN_ID}"

while true; do
    STATE=$(aws glue get-job-run --job-name "$JOB_NAME" --run-id "$RUN_ID" \
            --region "$REGION" --query 'JobRun.JobRunState' --output text)
    echo "    state: ${STATE}"
    case "$STATE" in
        SUCCEEDED) break ;;
        FAILED|TIMEOUT|STOPPED)
            echo "ETL job ${STATE}. Error message:"
            aws glue get-job-run --job-name "$JOB_NAME" --run-id "$RUN_ID" \
                --region "$REGION" --query 'JobRun.ErrorMessage' --output text
            exit 1 ;;
    esac
    sleep 30
done

echo "==> 4/5 Running curated crawler (after ETL, so it sees the output)"
aws glue start-crawler --name "$CURATED_CRAWLER" --region "$REGION" 2>/dev/null || true
wait_for_crawler "$CURATED_CRAWLER"

echo "==> 5/5 Pipeline complete."
echo "    Query in Athena:  database ecommerce_curated_db, table orders_summary"
echo "    Load to Redshift: see sql/02_load_data.sql"

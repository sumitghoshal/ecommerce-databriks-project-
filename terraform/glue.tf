# Raw zone catalog (crawls the batch CSV/JSON input)
resource "aws_glue_catalog_database" "raw" {
  name = "ecommerce_raw_db"
}

resource "aws_glue_crawler" "raw" {
  name          = "${var.project_name}-raw-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.raw.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/batch/"
  }
}

# Curated zone catalog — THIS is what Athena and QuickSight query.
# Without it, Section 10's queries have no table to read from.
resource "aws_glue_catalog_database" "curated" {
  name = "ecommerce_curated_db"
}

resource "aws_glue_crawler" "curated" {
  name          = "${var.project_name}-curated-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.curated.name

  s3_target {
    path = "s3://${aws_s3_bucket.curated.bucket}/orders_summary/"
  }
}

# Upload the PySpark script to S3 as part of apply so the job always has a script
resource "aws_s3_object" "etl_script" {
  bucket = aws_s3_bucket.processed.id
  key    = "scripts/etl_job.py"
  source = "${path.module}/../glue-jobs/etl_job.py"
  etag   = filemd5("${path.module}/../glue-jobs/etl_job.py")
}

resource "aws_glue_job" "etl" {
  name         = "${var.project_name}-etl-job"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"

  # G.1X = 4 vCPU / 16GB per worker — the cheapest worker type that runs Spark
  # comfortably at this scale.
  worker_type       = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.processed.bucket}/${aws_s3_object.etl_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--RAW_BUCKET"                       = aws_s3_bucket.raw.bucket
    "--PROCESSED_BUCKET"                 = aws_s3_bucket.processed.bucket
    "--CURATED_BUCKET"                   = aws_s3_bucket.curated.bucket
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-bookmark-option"              = "job-bookmark-disable"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  timeout = 60
}

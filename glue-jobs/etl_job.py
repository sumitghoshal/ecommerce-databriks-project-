"""
AWS Glue ETL Job — E-Commerce batch + streaming pipeline.

Flow:
    raw/batch/orders/        (CSV, uploaded by scripts/generate_sample_data.py)
    raw/streaming/orders/    (GZIP JSON, delivered by Kinesis Firehose)
        -> clean, validate, conform types
        -> processed/orders/           (row-level Parquet)
        -> curated/orders_summary/     (monthly-by-product aggregate Parquet)

The curated output is what the `ecommerce-curated-crawler` catalogs, what
Athena/QuickSight query, and what Redshift COPYs into `fact_sales_monthly`.

Job parameters (set in terraform/glue.tf default_arguments):
    --RAW_BUCKET  --PROCESSED_BUCKET  --CURATED_BUCKET
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, IntegerType
from pyspark.sql.utils import AnalysisException

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
args = getResolvedOptions(
    sys.argv, ["JOB_NAME", "RAW_BUCKET", "PROCESSED_BUCKET", "CURATED_BUCKET"]
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

logger = glueContext.get_logger()

RAW_BUCKET = args["RAW_BUCKET"]
PROCESSED_BUCKET = args["PROCESSED_BUCKET"]
CURATED_BUCKET = args["CURATED_BUCKET"]

BATCH_PATH = f"s3://{RAW_BUCKET}/batch/orders/"
STREAM_PATH = f"s3://{RAW_BUCKET}/streaming/orders/"
PROCESSED_PATH = f"s3://{PROCESSED_BUCKET}/orders/"
CURATED_PATH = f"s3://{CURATED_BUCKET}/orders_summary/"

REQUIRED_COLUMNS = ["order_id", "customer_id", "product_id", "quantity", "amount"]


# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
def read_batch():
    """Read batch CSV orders. Returns None if the prefix is empty."""
    try:
        df = (
            spark.read.option("header", "true")
            .option("mode", "PERMISSIVE")
            .csv(BATCH_PATH)
        )
        if len(df.columns) == 0:
            return None
        logger.info(f"Batch source columns: {df.columns}")
        return df.withColumn("source", F.lit("batch"))
    except AnalysisException:
        logger.warn(f"No batch data found at {BATCH_PATH}")
        return None


def read_stream():
    """
    Read Firehose-delivered JSON events (GZIP, one JSON object per line).

    Streaming events use `event_type`/`event_id` rather than `order_id`, so we
    keep only purchases and conform them to the batch schema before union.
    """
    try:
        df = spark.read.json(STREAM_PATH)
        if len(df.columns) == 0:
            return None
        logger.info(f"Stream source columns: {df.columns}")

        if "event_type" in df.columns:
            df = df.filter(F.col("event_type") == "purchase")

        # Conform to the batch schema
        if "order_id" not in df.columns and "event_id" in df.columns:
            df = df.withColumnRenamed("event_id", "order_id")
        if "quantity" not in df.columns:
            df = df.withColumn("quantity", F.lit(1))
        if "order_date" not in df.columns and "timestamp" in df.columns:
            df = df.withColumn("order_date", F.col("timestamp"))

        return df.withColumn("source", F.lit("stream"))
    except AnalysisException:
        logger.warn(f"No streaming data found at {STREAM_PATH}")
        return None


def union_sources(batch_df, stream_df):
    """Union batch and stream on their shared columns."""
    if batch_df is None and stream_df is None:
        raise Exception(
            "No input data found in either the batch or streaming prefix. "
            "Upload data (scripts/generate_sample_data.py) or run the Kinesis "
            "producer before running this job."
        )
    if batch_df is None:
        return stream_df
    if stream_df is None:
        return batch_df

    shared = [c for c in batch_df.columns if c in stream_df.columns]
    logger.info(f"Unioning batch + stream on shared columns: {shared}")
    return batch_df.select(*shared).unionByName(stream_df.select(*shared))


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------
def clean_and_conform(df):
    """Drop invalid rows, dedupe, cast types, derive partition columns."""
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise Exception(
            f"Input is missing required columns: {missing}. Found: {df.columns}"
        )

    cleaned = (
        df.dropna(subset=REQUIRED_COLUMNS)
        .dropDuplicates(["order_id"])
        .withColumn("customer_id", F.col("customer_id").cast(IntegerType()))
        .withColumn("product_id", F.col("product_id").cast(IntegerType()))
        .withColumn("quantity", F.col("quantity").cast(IntegerType()))
        .withColumn("amount", F.col("amount").cast(DoubleType()))
    )

    # order_date may be a date string (batch) or an ISO timestamp (stream)
    cleaned = cleaned.withColumn(
        "order_date",
        F.coalesce(
            F.to_date(F.col("order_date")),
            F.to_date(F.to_timestamp(F.col("order_date"))),
        ),
    )

    # Drop rows whose casts produced nulls or whose values are nonsensical
    cleaned = cleaned.filter(
        F.col("amount").isNotNull()
        & (F.col("amount") >= 0)
        & F.col("quantity").isNotNull()
        & (F.col("quantity") > 0)
        & F.col("order_date").isNotNull()
    )

    return cleaned.withColumn("year", F.year("order_date")).withColumn(
        "month", F.month("order_date")
    )


def run_quality_checks(raw_count, df):
    """Fail the job loudly rather than silently publishing bad analytics."""
    clean_count = df.count()
    logger.info(f"Quality: {clean_count} clean rows out of {raw_count} raw rows")

    if clean_count == 0:
        raise Exception("Data quality check FAILED: 0 rows survived cleaning.")

    if raw_count > 0:
        dropped_ratio = (raw_count - clean_count) / raw_count
        if dropped_ratio > 0.30:
            raise Exception(
                f"Data quality check FAILED: dropped {dropped_ratio:.1%} of rows "
                f"({raw_count - clean_count}/{raw_count}). Investigate the source."
            )

    negative = df.filter(F.col("amount") < 0).count()
    if negative > 0:
        raise Exception(f"Data quality check FAILED: {negative} negative amounts.")

    distinct_ids = df.select("order_id").distinct().count()
    if distinct_ids != clean_count:
        raise Exception(
            f"Data quality check FAILED: duplicate order_ids remain "
            f"({clean_count - distinct_ids} duplicates)."
        )

    logger.info("All data quality checks passed.")
    return clean_count


def build_summary(df):
    """
    Monthly revenue per product.

    This grain — (year, month, product_id) — is exactly what
    sql/create_star_schema.sql defines as fact_sales_monthly. Keep the two in
    sync: adding a column here means adding it to the table and the COPY.
    """
    return df.groupBy("year", "month", "product_id").agg(
        F.round(F.sum("amount"), 2).alias("total_revenue"),
        F.count("order_id").alias("order_count"),
        F.sum("quantity").alias("total_quantity"),
        F.round(F.avg("amount"), 2).alias("avg_order_value"),
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    batch_df = read_batch()
    stream_df = read_stream()
    source_df = union_sources(batch_df, stream_df)

    raw_count = source_df.count()
    logger.info(f"Read {raw_count} raw rows.")

    transformed = clean_and_conform(source_df)
    clean_count = run_quality_checks(raw_count, transformed)

    # Processed zone: row-level Parquet, partitioned for efficient reads
    (
        transformed.write.mode("overwrite")
        .partitionBy("year", "month")
        .parquet(PROCESSED_PATH)
    )
    logger.info(f"Wrote {clean_count} rows to {PROCESSED_PATH}")

    # Curated zone: aggregate for the warehouse and BI tools.
    # NOT partitioned by year/month — Redshift COPY reads the columns from the
    # Parquet files themselves, and Hive-style partition directories would hide
    # year/month from the COPY, producing NULLs in those columns.
    summary = build_summary(transformed)
    summary_count = summary.count()
    summary.coalesce(1).write.mode("overwrite").parquet(CURATED_PATH)
    logger.info(f"Wrote {summary_count} summary rows to {CURATED_PATH}")

    job.commit()
    logger.info("ETL job completed successfully.")


if __name__ == "__main__":
    main()

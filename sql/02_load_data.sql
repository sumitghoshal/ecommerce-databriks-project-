-- ===========================================================================
-- Load curated Parquet from S3 into Redshift.
--
-- Replace the two placeholders before running:
--   <CURATED_BUCKET>   -> terraform output curated_bucket
--   <REDSHIFT_ROLE_ARN>-> terraform output redshift_iam_role_arn
--
-- The role MUST be the redshift role (trusted by redshift.amazonaws.com).
-- Using the Glue role here fails: Redshift cannot assume it.
-- ===========================================================================

TRUNCATE TABLE fact_sales_monthly;

COPY fact_sales_monthly (year, month, product_id, total_revenue, order_count,
                         total_quantity, avg_order_value)
FROM 's3://<CURATED_BUCKET>/orders_summary/'
IAM_ROLE '<REDSHIFT_ROLE_ARN>'
FORMAT AS PARQUET;

-- Load product dimension from the raw batch CSV
COPY dim_product (product_id, product_name, category, unit_price)
FROM 's3://<RAW_BUCKET>/batch/products/'
IAM_ROLE '<REDSHIFT_ROLE_ARN>'
CSV
IGNOREHEADER 1;

COPY dim_customer (customer_id, customer_name, email, city, signup_date)
FROM 's3://<RAW_BUCKET>/batch/customers/'
IAM_ROLE '<REDSHIFT_ROLE_ARN>'
CSV
IGNOREHEADER 1;

-- Verify the load and surface any errors
SELECT 'fact_sales_monthly' AS table_name, COUNT(*) AS rows FROM fact_sales_monthly
UNION ALL SELECT 'dim_product', COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_date', COUNT(*) FROM dim_date;

-- If a COPY fails, this shows exactly which row and column broke:
--   SELECT * FROM sys_load_error_detail ORDER BY start_time DESC LIMIT 10;

ANALYZE fact_sales_monthly;
ANALYZE dim_product;

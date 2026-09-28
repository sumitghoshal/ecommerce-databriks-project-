-- ===========================================================================
-- Athena queries against the DATA LAKE (no loading required)
--
-- Database: ecommerce_curated_db  (created by the curated Glue crawler)
-- Run the curated crawler AFTER the ETL job, or these tables will not exist.
-- ===========================================================================

-- Top products by revenue
SELECT
    product_id,
    SUM(total_revenue) AS revenue,
    SUM(order_count)   AS orders
FROM "ecommerce_curated_db"."orders_summary"
GROUP BY product_id
ORDER BY revenue DESC
LIMIT 10;

-- Monthly trend
SELECT
    year,
    month,
    SUM(total_revenue) AS revenue
FROM "ecommerce_curated_db"."orders_summary"
GROUP BY year, month
ORDER BY year, month;

-- Row-level analysis against the processed zone (has customer_id).
-- Requires a crawler on s3://<processed-bucket>/orders/ if you want this
-- catalogued — not created by default in terraform/glue.tf.
-- SELECT customer_id, SUM(amount) AS lifetime_value, COUNT(*) AS orders
-- FROM "ecommerce_processed_db"."orders"
-- GROUP BY customer_id
-- ORDER BY lifetime_value DESC
-- LIMIT 20;

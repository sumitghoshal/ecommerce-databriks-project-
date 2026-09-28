-- ===========================================================================
-- Redshift star schema
--
-- IMPORTANT — grain matters:
-- The Glue ETL job (glue-jobs/etl_job.py) produces a MONTHLY-BY-PRODUCT
-- aggregate. fact_sales_monthly matches that output exactly and is the table
-- the COPY in 02_load_data.sql populates.
--
-- dim_customer and dim_date are standard star-schema components included for
-- completeness. They are NOT populated by this pipeline as shipped — you would
-- load them from the processed (row-level) zone. See the note at the bottom.
-- ===========================================================================

DROP TABLE IF EXISTS fact_sales_monthly;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_date;

-- --------------------------------------------------------------------------
-- Dimensions
-- --------------------------------------------------------------------------
CREATE TABLE dim_product (
    product_id      INTEGER       NOT NULL,
    product_name    VARCHAR(200),
    category        VARCHAR(100),
    unit_price      DECIMAL(10,2),
    PRIMARY KEY (product_id)
)
DISTSTYLE ALL          -- small dimension: replicate to every node for fast joins
SORTKEY (product_id);

CREATE TABLE dim_customer (
    customer_id     INTEGER       NOT NULL,
    customer_name   VARCHAR(200),
    email           VARCHAR(200),
    city            VARCHAR(100),
    signup_date     DATE,
    PRIMARY KEY (customer_id)
)
DISTSTYLE ALL
SORTKEY (customer_id);

CREATE TABLE dim_date (
    date_id         INTEGER       NOT NULL,   -- YYYYMMDD
    full_date       DATE          NOT NULL,
    year            SMALLINT      NOT NULL,
    quarter         SMALLINT      NOT NULL,
    month           SMALLINT      NOT NULL,
    day             SMALLINT      NOT NULL,
    weekday         VARCHAR(10),
    is_weekend      BOOLEAN,
    PRIMARY KEY (date_id)
)
DISTSTYLE ALL
SORTKEY (date_id);

-- --------------------------------------------------------------------------
-- Fact table — matches the Glue job's curated output column-for-column
-- --------------------------------------------------------------------------
CREATE TABLE fact_sales_monthly (
    year              SMALLINT       NOT NULL,
    month             SMALLINT       NOT NULL,
    product_id        INTEGER        NOT NULL,
    total_revenue     DECIMAL(14,2)  NOT NULL,
    order_count       BIGINT         NOT NULL,
    total_quantity    BIGINT,
    avg_order_value   DECIMAL(12,2)
)
DISTKEY (product_id)              -- co-locate with dim_product joins
SORTKEY (year, month);            -- time-range scans are the common filter

-- --------------------------------------------------------------------------
-- Populate dim_date (10 years) using a Redshift-native recursive CTE
-- --------------------------------------------------------------------------
INSERT INTO dim_date
WITH RECURSIVE dates (d) AS (
    SELECT CAST('2020-01-01' AS DATE)
    UNION ALL
    SELECT DATEADD(day, 1, d) FROM dates WHERE d < CAST('2030-12-31' AS DATE)
)
SELECT
    CAST(TO_CHAR(d, 'YYYYMMDD') AS INTEGER)  AS date_id,
    d                                        AS full_date,
    EXTRACT(year    FROM d)                  AS year,
    EXTRACT(quarter FROM d)                  AS quarter,
    EXTRACT(month   FROM d)                  AS month,
    EXTRACT(day     FROM d)                  AS day,
    TO_CHAR(d, 'Day')                        AS weekday,
    CASE WHEN EXTRACT(dow FROM d) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend
FROM dates;

-- ===========================================================================
-- Extending to a row-level fact table
-- ===========================================================================
-- If you want per-order granularity (needed for "top customers" analysis),
-- load from the PROCESSED zone instead, which does have order_id/customer_id:
--
--   CREATE TABLE fact_sales (
--       order_id     VARCHAR(40) NOT NULL,
--       customer_id  INTEGER     NOT NULL,
--       product_id   INTEGER     NOT NULL,
--       date_id      INTEGER     NOT NULL,
--       quantity     INTEGER     NOT NULL,
--       amount       DECIMAL(12,2) NOT NULL
--   ) DISTKEY (customer_id) SORTKEY (date_id);
--
-- Note the processed Parquet has `order_date` (a DATE), not `date_id`. You must
-- either derive date_id in the ETL job, or COPY into a staging table and join
-- to dim_date on full_date during the INSERT.

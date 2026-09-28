-- ===========================================================================
-- Analytics queries — these back the QuickSight dashboard visuals
-- ===========================================================================

-- 1. Total revenue and orders (KPI tiles)
SELECT
    SUM(total_revenue) AS total_revenue,
    SUM(order_count)   AS total_orders,
    ROUND(SUM(total_revenue) / NULLIF(SUM(order_count), 0), 2) AS avg_order_value
FROM fact_sales_monthly;

-- 2. Revenue by product (top 10 bar chart)
SELECT
    f.product_id,
    p.product_name,
    p.category,
    SUM(f.total_revenue) AS revenue,
    SUM(f.order_count)   AS orders
FROM fact_sales_monthly f
LEFT JOIN dim_product p ON f.product_id = p.product_id
GROUP BY f.product_id, p.product_name, p.category
ORDER BY revenue DESC
LIMIT 10;

-- 3. Monthly sales trend (line chart)
SELECT
    year,
    month,
    SUM(total_revenue) AS revenue,
    SUM(order_count)   AS orders
FROM fact_sales_monthly
GROUP BY year, month
ORDER BY year, month;

-- 4. Revenue by category
SELECT
    COALESCE(p.category, 'unknown') AS category,
    SUM(f.total_revenue)            AS revenue,
    ROUND(100.0 * SUM(f.total_revenue) / SUM(SUM(f.total_revenue)) OVER (), 1) AS pct_of_total
FROM fact_sales_monthly f
LEFT JOIN dim_product p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;

-- 5. Month-over-month growth
SELECT
    year,
    month,
    SUM(total_revenue) AS revenue,
    LAG(SUM(total_revenue)) OVER (ORDER BY year, month) AS prev_month,
    ROUND(
        100.0 * (SUM(total_revenue) - LAG(SUM(total_revenue)) OVER (ORDER BY year, month))
        / NULLIF(LAG(SUM(total_revenue)) OVER (ORDER BY year, month), 0), 1
    ) AS mom_growth_pct
FROM fact_sales_monthly
GROUP BY year, month
ORDER BY year, month;

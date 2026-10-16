-- ============================================================
-- 19_trend_analytics.sql   |  BQ-29 to BQ-30 + FY boundary tests
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
-- Revenue basis: net_amount by bill_date.
-- Limitation: only two FYs exist and the generator has NO designed
-- seasonality (A-20), so monthly peaks/troughs are descriptive, not seasonal.
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-29: CUMULATIVE FY NET REVENUE vs THE PRIOR FY AT THE SAME POINT
-- Grain  : FY month number (1 = April ... 12 = March)
-- Method : monthly revenue -> running SUM() per FY -> place the two FYs
--          side by side on the same month number
-- ============================================================
WITH monthly AS (
    SELECT
        CASE WHEN bill_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
        -- April = 1 ... March = 12
        CASE WHEN EXTRACT(MONTH FROM bill_date) >= 4
             THEN EXTRACT(MONTH FROM bill_date) - 3
             ELSE EXTRACT(MONTH FROM bill_date) + 9 END::int                         AS fy_month,
        SUM(net_amount)                                                              AS net_revenue
    FROM billing
    GROUP BY fy, fy_month
),
cumulative AS (
    SELECT
        fy,
        fy_month,
        net_revenue,
        SUM(net_revenue) OVER (PARTITION BY fy ORDER BY fy_month) AS cumulative_revenue
    FROM monthly
)
SELECT
    c24.fy_month,
    TO_CHAR(TO_DATE(((c24.fy_month + 2) % 12 + 1)::text, 'MM'), 'Mon')    AS month_name,
    ROUND(c24.cumulative_revenue, 0)                                       AS cumulative_fy2023_24,
    ROUND(c25.cumulative_revenue, 0)                                       AS cumulative_fy2024_25,
    ROUND(100.0 * (c25.cumulative_revenue - c24.cumulative_revenue)
          / NULLIF(c24.cumulative_revenue, 0), 1)                          AS ytd_growth_pct
FROM cumulative c24
JOIN cumulative c25 ON c25.fy_month = c24.fy_month AND c25.fy = 'FY2024-25'
WHERE c24.fy = 'FY2023-24'
ORDER BY c24.fy_month;


-- ============================================================
-- BQ-30: PEAK AND TROUGH MONTHS IN EACH FY (VISITS AND NET REVENUE)
-- Grain  : month, ranked within its FY (1 = highest)
-- The business question is visit-based; net revenue is shown alongside.
-- Months that rank in the top 3 / bottom 3 in BOTH FYs are flagged.
-- Visits are counted by visit_date; revenue by bill_date.
-- ============================================================
WITH monthly_visits AS (
    SELECT DATE_TRUNC('month', visit_date)::date AS month_start, COUNT(*) AS visits
    FROM visits
    GROUP BY month_start
),
monthly_revenue AS (
    SELECT DATE_TRUNC('month', bill_date)::date AS month_start, SUM(net_amount) AS net_revenue
    FROM billing
    GROUP BY month_start
),
ranked AS (
    SELECT
        mv.month_start,
        CASE WHEN mv.month_start < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
        mv.visits,
        mr.net_revenue,
        RANK() OVER (PARTITION BY mv.month_start < DATE '2024-04-01' ORDER BY mv.visits DESC)      AS visit_rank_in_fy,
        RANK() OVER (PARTITION BY mv.month_start < DATE '2024-04-01' ORDER BY mr.net_revenue DESC) AS revenue_rank_in_fy
    FROM monthly_visits mv
    JOIN monthly_revenue mr ON mr.month_start = mv.month_start
)
SELECT
    fy,
    TO_CHAR(month_start, 'Mon YYYY')    AS month,
    visits,
    visit_rank_in_fy,
    ROUND(net_revenue, 0)               AS net_revenue,
    revenue_rank_in_fy,
    CASE WHEN visit_rank_in_fy <= 3  THEN 'Peak (visits)'
         WHEN visit_rank_in_fy >= 10 THEN 'Trough (visits)'
         ELSE '' END                    AS visit_flag
FROM ranked
ORDER BY fy, month_start;

-- BQ-30 consistency check: same calendar month top-3 or bottom-3 in both FYs?
WITH monthly_visits AS (
    SELECT DATE_TRUNC('month', visit_date)::date AS month_start, COUNT(*) AS visits
    FROM visits GROUP BY month_start
),
ranked AS (
    SELECT
        EXTRACT(MONTH FROM month_start) AS cal_month,
        month_start < DATE '2024-04-01' AS is_fy24,
        RANK() OVER (PARTITION BY month_start < DATE '2024-04-01' ORDER BY visits DESC) AS r
    FROM monthly_visits
)
SELECT
    TO_CHAR(TO_DATE(cal_month::text, 'MM'), 'Mon')     AS month_name,
    MAX(r) FILTER (WHERE is_fy24)                      AS rank_fy2023_24,
    MAX(r) FILTER (WHERE NOT is_fy24)                  AS rank_fy2024_25,
    CASE WHEN MAX(r) <= 3  THEN 'Top-3 in both FYs'
         WHEN MIN(r) >= 10 THEN 'Bottom-3 in both FYs'
         ELSE 'Not consistent' END                     AS pattern
FROM ranked
GROUP BY cal_month
ORDER BY CASE WHEN cal_month >= 4 THEN cal_month - 3 ELSE cal_month + 9 END;


-- ============================================================
-- FY BOUNDARY TEST (applies the same FY / quarter / fy_month logic used
-- in 13-19 to the four boundary dates)
-- ============================================================
WITH test_dates(test_date, expected_fy, expected_quarter, expected_fy_month) AS (
    VALUES (DATE '2023-04-01', 'FY2023-24', 'Q1', 1),
           (DATE '2024-03-31', 'FY2023-24', 'Q4', 12),
           (DATE '2024-04-01', 'FY2024-25', 'Q1', 1),
           (DATE '2025-03-31', 'FY2024-25', 'Q4', 12)
)
SELECT
    test_date,
    CASE WHEN test_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS derived_fy,
    CASE WHEN EXTRACT(MONTH FROM test_date) BETWEEN 4  AND 6  THEN 'Q1'
         WHEN EXTRACT(MONTH FROM test_date) BETWEEN 7  AND 9  THEN 'Q2'
         WHEN EXTRACT(MONTH FROM test_date) BETWEEN 10 AND 12 THEN 'Q3'
         ELSE 'Q4' END                                                         AS derived_quarter,
    (CASE WHEN EXTRACT(MONTH FROM test_date) >= 4 THEN EXTRACT(MONTH FROM test_date) - 3
          ELSE EXTRACT(MONTH FROM test_date) + 9 END)::int                     AS derived_fy_month,
    (SELECT COUNT(*) FROM billing b WHERE b.bill_date = t.test_date)           AS bills_on_date,
    CASE WHEN (CASE WHEN test_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END) = expected_fy
          AND (CASE WHEN EXTRACT(MONTH FROM test_date) BETWEEN 4  AND 6  THEN 'Q1'
                    WHEN EXTRACT(MONTH FROM test_date) BETWEEN 7  AND 9  THEN 'Q2'
                    WHEN EXTRACT(MONTH FROM test_date) BETWEEN 10 AND 12 THEN 'Q3'
                    ELSE 'Q4' END) = expected_quarter
          AND (CASE WHEN EXTRACT(MONTH FROM test_date) >= 4 THEN EXTRACT(MONTH FROM test_date) - 3
                    ELSE EXTRACT(MONTH FROM test_date) + 9 END) = expected_fy_month
         THEN 'PASS' ELSE 'FAIL' END                                           AS status
FROM test_dates t
ORDER BY test_date;


-- ============================================================
-- VALIDATION (trend analytics)
-- ============================================================
SELECT 'V19-1 Final cumulative revenue of each FY = FY net revenue' AS check_name,
       CASE WHEN (SELECT SUM(net_amount) FROM billing WHERE bill_date BETWEEN DATE '2023-04-01' AND DATE '2024-03-31')
               + (SELECT SUM(net_amount) FROM billing WHERE bill_date BETWEEN DATE '2024-04-01' AND DATE '2025-03-31')
               = (SELECT SUM(net_amount) FROM billing)
             AND NOT EXISTS (SELECT 1 FROM billing WHERE bill_date NOT BETWEEN DATE '2023-04-01' AND DATE '2025-03-31')
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V19-2 24 months present, 12 per FY, monthly visits sum to total visits',
       CASE WHEN (SELECT COUNT(DISTINCT DATE_TRUNC('month', visit_date)) FROM visits) = 24
             AND (SELECT COUNT(DISTINCT DATE_TRUNC('month', bill_date)) FROM billing WHERE bill_date < DATE '2024-04-01') = 12
             AND (SELECT SUM(c) FROM (SELECT COUNT(*) c FROM visits GROUP BY DATE_TRUNC('month', visit_date)) x)
               = (SELECT COUNT(*) FROM visits)
            THEN 'PASS' ELSE 'FAIL' END;

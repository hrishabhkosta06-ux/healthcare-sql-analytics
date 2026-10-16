-- ============================================================
-- 17_revenue_analytics.sql   |  BQ-20 to BQ-24
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
-- Metric definitions used in this file:
--   Gross revenue   = billing.gross_amount (sum of 5 charge components)
--   Discount        = billing.discount_amount
--   Net revenue     = billing.net_amount = gross - discount   (DEFAULT basis)
--   Collections     = SUM(payments.amount_paid) WHERE payment_status = 'Success'
--   Outstanding     = net revenue - collections   (never negative)
--   Collection rate = collections / net revenue
-- Revenue date = bill_date (IP bills are dated on discharge).
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-20a: MONTHLY NET REVENUE, MoM AND YoY GROWTH
-- Grain  : calendar month of bill_date
-- Method : GROUP BY month, then LAG(1) for previous month and LAG(12)
--          for the same month last year (available for FY2024-25 only)
-- ============================================================
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', bill_date)::date AS bill_month,
        SUM(net_amount)                      AS net_revenue,
        COUNT(*)                             AS bills
    FROM billing
    GROUP BY bill_month
)
SELECT
    bill_month,
    CASE WHEN bill_month < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
    bills,
    ROUND(net_revenue, 0)                                                AS net_revenue,
    ROUND(100.0 * (net_revenue - LAG(net_revenue) OVER (ORDER BY bill_month))
          / NULLIF(LAG(net_revenue) OVER (ORDER BY bill_month), 0), 1)   AS mom_growth_pct,
    ROUND(100.0 * (net_revenue - LAG(net_revenue, 12) OVER (ORDER BY bill_month))
          / NULLIF(LAG(net_revenue, 12) OVER (ORDER BY bill_month), 0), 1) AS yoy_growth_pct
FROM monthly
ORDER BY bill_month;


-- ============================================================
-- BQ-20b: QUARTERLY NET REVENUE AND QoQ GROWTH (Indian FY quarters)
-- Q1 = Apr-Jun, Q2 = Jul-Sep, Q3 = Oct-Dec, Q4 = Jan-Mar
-- ============================================================
WITH quarterly AS (
    SELECT
        CASE WHEN bill_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
        CASE
            WHEN EXTRACT(MONTH FROM bill_date) BETWEEN 4  AND 6  THEN 'Q1'
            WHEN EXTRACT(MONTH FROM bill_date) BETWEEN 7  AND 9  THEN 'Q2'
            WHEN EXTRACT(MONTH FROM bill_date) BETWEEN 10 AND 12 THEN 'Q3'
            ELSE 'Q4'
        END                                         AS fy_quarter,
        SUM(net_amount)                             AS net_revenue
    FROM billing
    GROUP BY fy, fy_quarter
)
SELECT
    fy,
    fy_quarter,
    ROUND(net_revenue, 0)                                                     AS net_revenue,
    ROUND(100.0 * (net_revenue - LAG(net_revenue) OVER (ORDER BY fy, fy_quarter))
          / NULLIF(LAG(net_revenue) OVER (ORDER BY fy, fy_quarter), 0), 1)    AS qoq_growth_pct,
    ROUND(100.0 * (net_revenue - LAG(net_revenue, 4) OVER (ORDER BY fy, fy_quarter))
          / NULLIF(LAG(net_revenue, 4) OVER (ORDER BY fy, fy_quarter), 0), 1) AS yoy_growth_pct
FROM quarterly
ORDER BY fy, fy_quarter;

-- BQ-20c: FY totals (gross, discount, net) and FY growth
SELECT
    CASE WHEN bill_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
    COUNT(*)                        AS bills,
    ROUND(SUM(gross_amount), 0)     AS gross_revenue,
    ROUND(SUM(discount_amount), 0)  AS discounts,
    ROUND(SUM(net_amount), 0)       AS net_revenue,
    ROUND(SUM(net_amount) / NULLIF(COUNT(*), 0), 0) AS avg_net_per_bill
FROM billing
GROUP BY fy
ORDER BY fy;


-- ============================================================
-- BQ-21: CHARGE COMPONENT MIX
-- Grain  : component (overall) and component x visit type
-- Basis  : GROSS (components are pre-discount; they sum to gross_amount)
-- ============================================================
SELECT
    ROUND(SUM(consultation_charges), 0) AS consultation,
    ROUND(SUM(procedure_charges), 0)    AS procedures,
    ROUND(SUM(room_charges), 0)         AS room,
    ROUND(SUM(pharmacy_charges), 0)     AS pharmacy,
    ROUND(SUM(diagnostics_charges), 0)  AS diagnostics,
    ROUND(SUM(gross_amount), 0)         AS gross_total,
    ROUND(100.0 * SUM(consultation_charges) / NULLIF(SUM(gross_amount), 0), 1) AS consultation_pct,
    ROUND(100.0 * SUM(procedure_charges)    / NULLIF(SUM(gross_amount), 0), 1) AS procedures_pct,
    ROUND(100.0 * SUM(room_charges)         / NULLIF(SUM(gross_amount), 0), 1) AS room_pct,
    ROUND(100.0 * SUM(pharmacy_charges)     / NULLIF(SUM(gross_amount), 0), 1) AS pharmacy_pct,
    ROUND(100.0 * SUM(diagnostics_charges)  / NULLIF(SUM(gross_amount), 0), 1) AS diagnostics_pct
FROM billing;

SELECT
    v.visit_type,
    ROUND(100.0 * SUM(b.consultation_charges) / NULLIF(SUM(b.gross_amount), 0), 1) AS consultation_pct,
    ROUND(100.0 * SUM(b.procedure_charges)    / NULLIF(SUM(b.gross_amount), 0), 1) AS procedures_pct,
    ROUND(100.0 * SUM(b.room_charges)         / NULLIF(SUM(b.gross_amount), 0), 1) AS room_pct,
    ROUND(100.0 * SUM(b.pharmacy_charges)     / NULLIF(SUM(b.gross_amount), 0), 1) AS pharmacy_pct,
    ROUND(100.0 * SUM(b.diagnostics_charges)  / NULLIF(SUM(b.gross_amount), 0), 1) AS diagnostics_pct,
    ROUND(SUM(b.gross_amount), 0)                                                  AS gross_total
FROM billing b
JOIN visits v ON v.visit_id = b.visit_id
GROUP BY v.visit_type
ORDER BY gross_total DESC;


-- ============================================================
-- BQ-22: NET REVENUE AND AVERAGE BILL BY PAYER
-- Grain  : payer_type
-- ============================================================
SELECT
    payer_type,
    COUNT(*)                                                    AS bills,
    ROUND(SUM(net_amount), 0)                                   AS net_revenue,
    ROUND(100.0 * SUM(net_amount) / SUM(SUM(net_amount)) OVER (), 1) AS revenue_share_pct,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS bill_share_pct,
    ROUND(AVG(net_amount), 0)                                   AS avg_net_bill
FROM billing
GROUP BY payer_type
ORDER BY net_revenue DESC;


-- ============================================================
-- BQ-23: DISCOUNT RATE BY DEPARTMENT AND PAYER
-- KPI    : SUM(discount) / SUM(gross)   (NULLIF guards a zero gross)
-- Grain  : department x payer_type
-- Note   : discount policy is a generator rule by payer (A-14), so payer
--          differences are Assumption-driven by design.
-- ============================================================
SELECT
    d.department_name,
    b.payer_type,
    COUNT(*)                                                       AS bills,
    ROUND(SUM(b.gross_amount), 0)                                  AS gross_revenue,
    ROUND(SUM(b.discount_amount), 0)                               AS discounts,
    ROUND(100.0 * SUM(b.discount_amount) / NULLIF(SUM(b.gross_amount), 0), 2) AS discount_rate_pct
FROM billing b
JOIN visits v      ON v.visit_id = b.visit_id
JOIN departments d ON d.department_id = v.department_id
GROUP BY d.department_name, b.payer_type
ORDER BY d.department_name, b.payer_type;

-- BQ-23 summary by payer and by department
SELECT 'payer' AS level, payer_type AS name,
       ROUND(100.0 * SUM(discount_amount) / NULLIF(SUM(gross_amount), 0), 2) AS discount_rate_pct
FROM billing GROUP BY payer_type
UNION ALL
SELECT 'department', d.department_name,
       ROUND(100.0 * SUM(b.discount_amount) / NULLIF(SUM(b.gross_amount), 0), 2)
FROM billing b JOIN visits v ON v.visit_id = b.visit_id
JOIN departments d ON d.department_id = v.department_id
GROUP BY d.department_name
ORDER BY level DESC, discount_rate_pct DESC;


-- ============================================================
-- BQ-24a: COLLECTIONS, OUTSTANDING AND COLLECTION RATE BY PAYER
-- Grain  : payer_type
-- Method : aggregate successful payments PER BILL first, then join to
--          billing (avoids multiplying net_amount by the number of payments)
-- Failed attempts are excluded from collections and from outstanding.
-- ============================================================
WITH paid_per_bill AS (
    SELECT bill_id, SUM(amount_paid) AS collected
    FROM payments
    WHERE payment_status = 'Success'
    GROUP BY bill_id
)
SELECT
    b.payer_type,
    COUNT(*)                                                         AS bills,
    ROUND(SUM(b.net_amount), 0)                                      AS net_revenue,
    ROUND(SUM(COALESCE(p.collected, 0)), 0)                          AS collected,
    ROUND(SUM(b.net_amount - COALESCE(p.collected, 0)), 0)           AS outstanding,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) / NULLIF(SUM(b.net_amount), 0), 1) AS collection_rate_pct,
    COUNT(*) FILTER (WHERE p.collected IS NULL)                      AS bills_with_no_payment
FROM billing b
LEFT JOIN paid_per_bill p ON p.bill_id = b.bill_id
GROUP BY b.payer_type
ORDER BY collection_rate_pct, b.payer_type;

-- ============================================================
-- BQ-24b: COLLECTION RATE BY BILLING-QUARTER COHORT x PAYER
-- RIGHT-CENSORING: bills raised near 31 Mar 2025 have had little time to
-- settle (institutional payers settle after a lag, A-15). Lower rates in
-- the latest cohorts are expected and are NOT a performance signal.
-- ============================================================
WITH paid_per_bill AS (
    SELECT bill_id, SUM(amount_paid) AS collected
    FROM payments
    WHERE payment_status = 'Success'
    GROUP BY bill_id
)
SELECT
    CASE WHEN b.bill_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END
      || ' ' ||
    CASE
        WHEN EXTRACT(MONTH FROM b.bill_date) BETWEEN 4  AND 6  THEN 'Q1'
        WHEN EXTRACT(MONTH FROM b.bill_date) BETWEEN 7  AND 9  THEN 'Q2'
        WHEN EXTRACT(MONTH FROM b.bill_date) BETWEEN 10 AND 12 THEN 'Q3'
        ELSE 'Q4'
    END                                                                    AS bill_quarter,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) FILTER (WHERE b.payer_type = 'Self-pay')
          / NULLIF(SUM(b.net_amount) FILTER (WHERE b.payer_type = 'Self-pay'), 0), 1)      AS self_pay_pct,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) FILTER (WHERE b.payer_type = 'Insurance-TPA')
          / NULLIF(SUM(b.net_amount) FILTER (WHERE b.payer_type = 'Insurance-TPA'), 0), 1) AS insurance_pct,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) FILTER (WHERE b.payer_type = 'Corporate')
          / NULLIF(SUM(b.net_amount) FILTER (WHERE b.payer_type = 'Corporate'), 0), 1)     AS corporate_pct,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) FILTER (WHERE b.payer_type = 'Govt scheme')
          / NULLIF(SUM(b.net_amount) FILTER (WHERE b.payer_type = 'Govt scheme'), 0), 1)   AS govt_scheme_pct,
    ROUND(100.0 * SUM(COALESCE(p.collected, 0)) / NULLIF(SUM(b.net_amount), 0), 1)        AS all_payers_pct
FROM billing b
LEFT JOIN paid_per_bill p ON p.bill_id = b.bill_id
GROUP BY bill_quarter
ORDER BY bill_quarter;


-- ============================================================
-- VALIDATION (revenue analytics)
-- ============================================================
WITH paid_per_bill AS (
    SELECT bill_id, SUM(amount_paid) AS collected
    FROM payments WHERE payment_status = 'Success' GROUP BY bill_id
)
SELECT 'V17-1 Monthly net revenue sums to billing net revenue' AS check_name,
       CASE WHEN (SELECT SUM(s) FROM (SELECT SUM(net_amount) s FROM billing
                  GROUP BY DATE_TRUNC('month', bill_date)) x) = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V17-2 Payer net revenue sums to billing net revenue',
       CASE WHEN (SELECT SUM(s) FROM (SELECT SUM(net_amount) s FROM billing GROUP BY payer_type) x)
               = (SELECT SUM(net_amount) FROM billing) THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V17-3 Components sum to gross; gross - discount = net (totals)',
       CASE WHEN (SELECT SUM(consultation_charges + procedure_charges + room_charges
                         + pharmacy_charges + diagnostics_charges) FROM billing) = (SELECT SUM(gross_amount) FROM billing)
             AND (SELECT SUM(gross_amount) - SUM(discount_amount) FROM billing) = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V17-4 Successful collections <= net revenue for every bill',
       CASE WHEN NOT EXISTS (SELECT 1 FROM billing b JOIN paid_per_bill p ON p.bill_id = b.bill_id
                             WHERE p.collected > b.net_amount) THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V17-5 Outstanding >= 0 and collected + outstanding = net revenue',
       CASE WHEN (SELECT SUM(COALESCE(p.collected, 0)) + SUM(b.net_amount - COALESCE(p.collected, 0))
                  FROM billing b LEFT JOIN paid_per_bill p ON p.bill_id = b.bill_id)
               = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V17-6 Failed payments excluded: collections = SUM(Success) only',
       CASE WHEN (SELECT SUM(collected) FROM paid_per_bill)
               = (SELECT SUM(amount_paid) FROM payments WHERE payment_status = 'Success')
             AND (SELECT COUNT(*) FROM payments WHERE payment_status = 'Failed') > 0
            THEN 'PASS' ELSE 'FAIL' END;

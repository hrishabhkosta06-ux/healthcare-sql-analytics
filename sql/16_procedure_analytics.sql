-- ============================================================
-- 16_procedure_analytics.sql   |  BQ-16 to BQ-19
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
--
-- REVENUE BASIS FOR PROCEDURES (documentation/kpi_definitions.md):
--   Procedure revenue = visit_procedures.charged_amount (line level, GROSS,
--   before the bill-level discount). Each line has its own amount, so no
--   visit-level bill amount is ever copied onto several procedure rows.
--   SUM(charged_amount) = SUM(billing.procedure_charges); it is NOT equal
--   to net revenue, because bills also carry consultation, room, pharmacy
--   and diagnostics charges and discounts are applied per bill.
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-16: PROCEDURE VOLUME AND PROCEDURE REVENUE
-- Grain  : procedure (full window)
-- Volume : SUM(quantity) (units/sessions); lines = times performed
-- ============================================================
SELECT
    pr.procedure_name,
    d.department_name,
    pr.procedure_category,
    COUNT(*)                                                   AS times_performed,
    SUM(vp.quantity)                                           AS units,
    ROUND(SUM(vp.charged_amount), 0)                           AS procedure_revenue_gross,
    ROUND(SUM(vp.charged_amount) / NULLIF(SUM(vp.quantity), 0), 0) AS avg_revenue_per_unit,
    RANK() OVER (ORDER BY SUM(vp.quantity) DESC)               AS rank_volume,
    RANK() OVER (ORDER BY SUM(vp.charged_amount) DESC)         AS rank_revenue
FROM visit_procedures vp
JOIN procedures pr ON pr.procedure_id = vp.procedure_id
JOIN departments d ON d.department_id = pr.department_id
GROUP BY pr.procedure_name, d.department_name, pr.procedure_category
ORDER BY rank_revenue, pr.procedure_name;

-- BQ-16 summary by procedure category
SELECT
    pr.procedure_category,
    COUNT(DISTINCT pr.procedure_id)                            AS procedures,
    SUM(vp.quantity)                                           AS units,
    ROUND(SUM(vp.charged_amount), 0)                           AS procedure_revenue_gross,
    ROUND(100.0 * SUM(vp.quantity) / SUM(SUM(vp.quantity)) OVER (), 1)             AS volume_share_pct,
    ROUND(100.0 * SUM(vp.charged_amount) / SUM(SUM(vp.charged_amount)) OVER (), 1) AS revenue_share_pct
FROM visit_procedures vp
JOIN procedures pr ON pr.procedure_id = vp.procedure_id
GROUP BY pr.procedure_category
ORDER BY procedure_revenue_gross DESC;


-- ============================================================
-- BQ-17: EACH PROCEDURE'S CONTRIBUTION TO PROCEDURE REVENUE
-- Grain  : procedure
-- KPI    : procedure charged_amount / total charged_amount (%), with a
--          running cumulative share to show concentration (Pareto view)
-- ============================================================
WITH proc_rev AS (
    SELECT pr.procedure_name, SUM(vp.charged_amount) AS revenue
    FROM visit_procedures vp
    JOIN procedures pr ON pr.procedure_id = vp.procedure_id
    GROUP BY pr.procedure_name
)
SELECT
    procedure_name,
    ROUND(revenue, 0)                                                AS procedure_revenue_gross,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)                 AS contribution_pct,
    ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC, procedure_name)
          / SUM(revenue) OVER (), 1)                                 AS cumulative_pct
FROM proc_rev
ORDER BY revenue DESC, procedure_name;

-- BQ-17 context: procedure charges as a share of gross billed amount
SELECT
    ROUND(SUM(procedure_charges), 0)                                 AS procedure_charges,
    ROUND(SUM(gross_amount), 0)                                      AS gross_billed,
    ROUND(100.0 * SUM(procedure_charges) / NULLIF(SUM(gross_amount), 0), 1) AS procedure_share_of_gross_pct
FROM billing;


-- ============================================================
-- BQ-18: MONTHLY PROCEDURE VOLUME AND MoM CHANGE
-- Grain  : month of procedure_date (network)
-- Method : monthly SUM(quantity), then LAG for previous month
-- ============================================================
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', procedure_date)::date AS proc_month,
        SUM(quantity)                             AS units,
        COUNT(*)                                  AS times_performed
    FROM visit_procedures
    GROUP BY proc_month
)
SELECT
    proc_month,
    units,
    times_performed,
    LAG(units) OVER (ORDER BY proc_month)                               AS prev_month_units,
    ROUND(100.0 * (units - LAG(units) OVER (ORDER BY proc_month))
          / NULLIF(LAG(units) OVER (ORDER BY proc_month), 0), 1)        AS mom_change_pct
FROM monthly
ORDER BY proc_month;


-- ============================================================
-- BQ-19: PROCEDURES MOST ASSOCIATED WITH INPATIENT ADMISSIONS
-- Grain  : procedure
-- KPI    : IP share = units performed during IP stays / all units
-- Rule   : minimum 30 units in total (threshold fixed before running)
-- Note   : DESCRIPTIVE. Which settings a procedure can occur in is a
--          generator configuration (A-07 care-setting flags), so IP-only
--          procedures show 100% by construction.
-- ============================================================
SELECT
    pr.procedure_name,
    d.department_name,
    SUM(vp.quantity)                                                AS total_units,
    COALESCE(SUM(vp.quantity) FILTER (WHERE v.visit_type = 'IP'), 0) AS ip_units,
    ROUND(100.0 * COALESCE(SUM(vp.quantity) FILTER (WHERE v.visit_type = 'IP'), 0)
          / NULLIF(SUM(vp.quantity), 0), 1)                         AS ip_share_pct,
    STRING_AGG(DISTINCT v.visit_type, ', ' ORDER BY v.visit_type)   AS settings_seen
FROM visit_procedures vp
JOIN visits v      ON v.visit_id = vp.visit_id
JOIN procedures pr ON pr.procedure_id = vp.procedure_id
JOIN departments d ON d.department_id = pr.department_id
GROUP BY pr.procedure_name, d.department_name
HAVING SUM(vp.quantity) >= 30
ORDER BY ip_share_pct DESC, ip_units DESC, pr.procedure_name;


-- ============================================================
-- VALIDATION (procedure analytics)
-- ============================================================
SELECT 'V16-1 Procedure revenue (lines) = SUM(billing.procedure_charges)' AS check_name,
       CASE WHEN (SELECT SUM(charged_amount) FROM visit_procedures)
               = (SELECT SUM(procedure_charges) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V16-2 Procedure revenue by procedure sums to line total (no multiplication)',
       CASE WHEN (SELECT SUM(s) FROM (SELECT SUM(charged_amount) s FROM visit_procedures GROUP BY procedure_id) x)
               = (SELECT SUM(charged_amount) FROM visit_procedures)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V16-3 Monthly procedure units sum to total units',
       CASE WHEN (SELECT SUM(u) FROM (SELECT SUM(quantity) u FROM visit_procedures
                  GROUP BY DATE_TRUNC('month', procedure_date)) x)
               = (SELECT SUM(quantity) FROM visit_procedures)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V16-4 Contribution percentages sum to 100',
       CASE WHEN (SELECT ROUND(SUM(p), 6) FROM (SELECT 100.0 * SUM(charged_amount)
                  / (SELECT SUM(charged_amount) FROM visit_procedures) p
                  FROM visit_procedures GROUP BY procedure_id) x) = 100
            THEN 'PASS' ELSE 'FAIL' END;

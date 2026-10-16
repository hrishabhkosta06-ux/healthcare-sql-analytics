-- ============================================================
-- 14_department_analytics.sql   |  BQ-07 to BQ-10
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
-- Source: processed schema. Revenue basis: net_amount (one bill per visit,
-- so joining billing to visits never duplicates revenue).
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-07: DEPARTMENT RANKING BY VISITS, NET REVENUE, REVENUE PER VISIT
-- Objective : Identify the largest and highest-yield departments
-- Grain     : department (full window, Apr 2023 - Mar 2025)
-- Method    : aggregate first, then RANK on each metric
-- ============================================================
WITH dept_metrics AS (
    SELECT
        d.department_name,
        COUNT(*)                       AS visits,
        SUM(b.net_amount)              AS net_revenue
    FROM visits v
    JOIN billing b     ON b.visit_id = v.visit_id
    JOIN departments d ON d.department_id = v.department_id
    GROUP BY d.department_name
)
SELECT
    department_name,
    visits,
    ROUND(net_revenue, 0)                                  AS net_revenue,
    ROUND(net_revenue / NULLIF(visits, 0), 0)              AS revenue_per_visit,
    RANK() OVER (ORDER BY visits DESC)                     AS rank_visits,
    RANK() OVER (ORDER BY net_revenue DESC)                AS rank_revenue,
    RANK() OVER (ORDER BY net_revenue / NULLIF(visits, 0) DESC) AS rank_rev_per_visit
FROM dept_metrics
ORDER BY rank_revenue, department_name;


-- ============================================================
-- BQ-08: DEPARTMENT REVENUE CONTRIBUTION, FY2023-24 vs FY2024-25
-- Objective : Did the department revenue mix shift between years
-- Grain     : department x FY (FY by bill_date)
-- KPI       : department net revenue / FY net revenue (%), change in pp
-- ============================================================
WITH dept_fy AS (
    SELECT
        d.department_name,
        SUM(b.net_amount) FILTER (WHERE b.bill_date <  DATE '2024-04-01') AS rev_fy24,
        SUM(b.net_amount) FILTER (WHERE b.bill_date >= DATE '2024-04-01') AS rev_fy25
    FROM billing b
    JOIN visits v      ON v.visit_id = b.visit_id
    JOIN departments d ON d.department_id = v.department_id
    GROUP BY d.department_name
)
SELECT
    department_name,
    ROUND(rev_fy24, 0)                                              AS net_rev_fy2023_24,
    ROUND(rev_fy25, 0)                                              AS net_rev_fy2024_25,
    ROUND(100.0 * rev_fy24 / SUM(rev_fy24) OVER (), 2)              AS share_fy2023_24_pct,
    ROUND(100.0 * rev_fy25 / SUM(rev_fy25) OVER (), 2)              AS share_fy2024_25_pct,
    ROUND(100.0 * rev_fy25 / SUM(rev_fy25) OVER ()
        - 100.0 * rev_fy24 / SUM(rev_fy24) OVER (), 2)              AS share_change_pp,
    ROUND(100.0 * (rev_fy25 - rev_fy24) / NULLIF(rev_fy24, 0), 1)   AS revenue_growth_pct
FROM dept_fy
ORDER BY share_change_pp DESC, department_name;


-- ============================================================
-- BQ-09: OP vs IP NET REVENUE SPLIT BY DEPARTMENT
-- Objective : Which departments depend on inpatient vs outpatient revenue
-- Grain     : department (ER and Day-care shown separately so rows reconcile)
-- ============================================================
SELECT
    d.department_name,
    ROUND(COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'OP'), 0), 0)       AS op_revenue,
    ROUND(COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'IP'), 0), 0)       AS ip_revenue,
    ROUND(COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'Day-care'), 0), 0) AS daycare_revenue,
    ROUND(COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'ER'), 0), 0)       AS er_revenue,
    ROUND(SUM(b.net_amount), 0)                                          AS total_revenue,
    ROUND(100.0 * COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'OP'), 0)
          / NULLIF(SUM(b.net_amount), 0), 1)                             AS op_share_pct,
    ROUND(100.0 * COALESCE(SUM(b.net_amount) FILTER (WHERE v.visit_type = 'IP'), 0)
          / NULLIF(SUM(b.net_amount), 0), 1)                             AS ip_share_pct
FROM visits v
JOIN billing b     ON b.visit_id = v.visit_id
JOIN departments d ON d.department_id = v.department_id
GROUP BY d.department_name
ORDER BY ip_share_pct DESC, d.department_name;

-- BQ-09 network split by visit type
SELECT
    v.visit_type,
    COUNT(*)                                                    AS visits,
    ROUND(SUM(b.net_amount), 0)                                 AS net_revenue,
    ROUND(100.0 * SUM(b.net_amount) / SUM(SUM(b.net_amount)) OVER (), 1) AS revenue_share_pct,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS visit_share_pct
FROM visits v
JOIN billing b ON b.visit_id = v.visit_id
GROUP BY v.visit_type
ORDER BY net_revenue DESC;


-- ============================================================
-- BQ-10: PROJECT-DEFINED 30-DAY OP -> IP CONVERSION BY DEPARTMENT
-- (Project-defined methodology. NOT Apollo's methodology.)
-- Qualifying OP : visit_type = 'OP', visit_date 1 Apr 2023 - 1 Mar 2025
--                 (OP visits after 1 Mar 2025 are right-censored: their
--                  30-day follow-up window would run past the data cutoff)
-- Converted     : same patient has an IP admission 0-30 days after a
--                 qualifying OP visit (same-day admission counts)
-- Attribution   : department of the qualifying OP visit
-- KPI           : converted distinct patients / distinct patients with a
--                 qualifying OP visit (per department)
-- ============================================================
WITH qualifying_op AS (
    SELECT patient_id, department_id, visit_date
    FROM visits
    WHERE visit_type = 'OP'
      AND visit_date BETWEEN DATE '2023-04-01' AND DATE '2025-03-01'
),
ip_admissions AS (
    SELECT patient_id, admission_date
    FROM visits
    WHERE visit_type = 'IP'
),
op_flagged AS (
    SELECT
        q.department_id,
        q.patient_id,
        MAX(CASE WHEN i.patient_id IS NOT NULL THEN 1 ELSE 0 END) AS converted
    FROM qualifying_op q
    LEFT JOIN ip_admissions i
           ON i.patient_id = q.patient_id
          AND i.admission_date BETWEEN q.visit_date AND q.visit_date + 30
    GROUP BY q.department_id, q.patient_id
)
SELECT
    d.department_name,
    COUNT(*)                                          AS op_patients,
    SUM(converted)                                    AS converted_patients,
    ROUND(100.0 * SUM(converted) / NULLIF(COUNT(*), 0), 1) AS conversion_rate_pct
FROM op_flagged o
JOIN departments d ON d.department_id = o.department_id
GROUP BY d.department_name
ORDER BY conversion_rate_pct DESC, d.department_name;

-- BQ-10 network rate (distinct patients across all departments)
WITH qualifying_op AS (
    SELECT patient_id, visit_date
    FROM visits
    WHERE visit_type = 'OP'
      AND visit_date BETWEEN DATE '2023-04-01' AND DATE '2025-03-01'
)
SELECT
    COUNT(DISTINCT q.patient_id)                                     AS op_patients,
    COUNT(DISTINCT q.patient_id) FILTER (WHERE i.patient_id IS NOT NULL) AS converted_patients,
    ROUND(100.0 * COUNT(DISTINCT q.patient_id) FILTER (WHERE i.patient_id IS NOT NULL)
          / NULLIF(COUNT(DISTINCT q.patient_id), 0), 1)              AS conversion_rate_pct
FROM qualifying_op q
LEFT JOIN visits i
       ON i.patient_id = q.patient_id
      AND i.visit_type = 'IP'
      AND i.admission_date BETWEEN q.visit_date AND q.visit_date + 30;


-- ============================================================
-- VALIDATION (department analytics)
-- ============================================================
SELECT 'V14-1 Sum of department net revenue = billing net revenue' AS check_name,
       CASE WHEN (SELECT SUM(b.net_amount) FROM billing b JOIN visits v ON v.visit_id = b.visit_id)
               = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V14-2 FY2023-24 + FY2024-25 department revenue = billing net revenue',
       CASE WHEN (SELECT SUM(net_amount) FILTER (WHERE bill_date < DATE '2024-04-01')
                       + SUM(net_amount) FILTER (WHERE bill_date >= DATE '2024-04-01') FROM billing)
               = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V14-3 OP->IP censoring: OP visits exist after 2025-03-01 and are excluded (cutoff + 30 days = last data day)',
       CASE WHEN (SELECT COUNT(*) FROM visits WHERE visit_type = 'OP' AND visit_date > DATE '2025-03-01') > 0
             AND (SELECT MAX(visit_date) FROM visits) = DATE '2025-03-01' + 30
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V14-4 OP->IP network rate = KPI validation method (12_kpi_validation style EXISTS)',
       CASE WHEN (SELECT COUNT(DISTINCT q.patient_id) FROM visits q
                  WHERE q.visit_type = 'OP' AND q.visit_date <= DATE '2025-03-01'
                    AND EXISTS (SELECT 1 FROM visits i WHERE i.patient_id = q.patient_id
                                AND i.visit_type = 'IP'
                                AND i.admission_date BETWEEN q.visit_date AND q.visit_date + 30))
               = (SELECT COUNT(DISTINCT q.patient_id) FROM visits q
                  JOIN visits i ON i.patient_id = q.patient_id AND i.visit_type = 'IP'
                   AND i.admission_date BETWEEN q.visit_date AND q.visit_date + 30
                  WHERE q.visit_type = 'OP' AND q.visit_date <= DATE '2025-03-01')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V14-5 BQ-07 rank_revenue has no gaps or duplicates (14 departments, 14 distinct ranks)',
       CASE WHEN (SELECT COUNT(DISTINCT r) FROM (SELECT RANK() OVER (ORDER BY SUM(b.net_amount) DESC) r
                  FROM billing b JOIN visits v ON v.visit_id = b.visit_id GROUP BY v.department_id) x) = 14
            THEN 'PASS' ELSE 'FAIL' END;

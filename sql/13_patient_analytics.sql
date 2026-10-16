-- ============================================================
-- 13_patient_analytics.sql   |  BQ-01 to BQ-06
-- Apollo Hospitals - Healthcare Operations & Revenue Analytics using SQL
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
-- Source: processed schema only. Revenue basis: net_amount.
-- Indian FY: FY2023-24 = 1 Apr 2023 - 31 Mar 2024; FY2024-25 = 1 Apr 2024 - 31 Mar 2025
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-01: UNIQUE PATIENTS BY MONTH, FACILITY AND VISIT TYPE
-- Objective : Measure patient volume across time, location, service line
-- Grain     : month x facility x visit_type
-- Note      : a patient seen as OP and IP in the same month is counted in
--             both rows, so rows do not add up to monthly unique patients.
-- ============================================================
SELECT
    DATE_TRUNC('month', v.visit_date)::date AS visit_month,
    f.facility_name,
    v.visit_type,
    COUNT(DISTINCT v.patient_id)            AS unique_patients,
    COUNT(*)                                AS visits
FROM visits v
JOIN facilities f ON f.facility_id = v.facility_id
GROUP BY visit_month, f.facility_name, v.visit_type
ORDER BY visit_month, f.facility_name, v.visit_type;

-- BQ-01 summary: unique patients per month (network) and per FY
SELECT
    CASE WHEN visit_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
    COUNT(DISTINCT patient_id)                                          AS unique_patients,
    COUNT(*)                                                            AS visits,
    ROUND(COUNT(*)::numeric / NULLIF(COUNT(DISTINCT patient_id), 0), 2) AS visits_per_patient
FROM visits
GROUP BY fy
ORDER BY fy;


-- ============================================================
-- BQ-02: AGE AND GENDER DISTRIBUTION ACROSS DEPARTMENTS
-- Objective : Profile who uses each department
-- Grain     : department x age_group x gender (distinct patients)
-- Method    : age is taken at the patient's FIRST visit to that department,
--             so each patient appears once per department.
-- ============================================================
WITH first_dept_visit AS (
    SELECT
        patient_id,
        department_id,
        MIN(visit_date) AS first_visit_date
    FROM visits
    GROUP BY patient_id, department_id
),
patient_age AS (
    SELECT
        fdv.department_id,
        p.gender,
        DATE_PART('year', AGE(fdv.first_visit_date, p.date_of_birth)) AS age_years
    FROM first_dept_visit fdv
    JOIN patients p ON p.patient_id = fdv.patient_id
)
SELECT
    d.department_name,
    CASE
        WHEN pa.age_years < 18 THEN '0-17'
        WHEN pa.age_years < 30 THEN '18-29'
        WHEN pa.age_years < 45 THEN '30-44'
        WHEN pa.age_years < 60 THEN '45-59'
        WHEN pa.age_years < 75 THEN '60-74'
        ELSE '75+'
    END                 AS age_group,
    pa.gender,
    COUNT(*)            AS patients
FROM patient_age pa
JOIN departments d ON d.department_id = pa.department_id
GROUP BY d.department_name, age_group, pa.gender
ORDER BY d.department_name, age_group, pa.gender;

-- BQ-02 summary: network age-group x gender (age at first-ever visit)
WITH first_visit AS (
    SELECT patient_id, MIN(visit_date) AS first_visit_date
    FROM visits
    GROUP BY patient_id
)
SELECT
    CASE
        WHEN DATE_PART('year', AGE(fv.first_visit_date, p.date_of_birth)) < 18 THEN '0-17'
        WHEN DATE_PART('year', AGE(fv.first_visit_date, p.date_of_birth)) < 30 THEN '18-29'
        WHEN DATE_PART('year', AGE(fv.first_visit_date, p.date_of_birth)) < 45 THEN '30-44'
        WHEN DATE_PART('year', AGE(fv.first_visit_date, p.date_of_birth)) < 60 THEN '45-59'
        WHEN DATE_PART('year', AGE(fv.first_visit_date, p.date_of_birth)) < 75 THEN '60-74'
        ELSE '75+'
    END                                                         AS age_group,
    COUNT(*) FILTER (WHERE p.gender = 'Male')                   AS male,
    COUNT(*) FILTER (WHERE p.gender = 'Female')                 AS female,
    COUNT(*) FILTER (WHERE p.gender = 'Other')                  AS other,
    COUNT(*)                                                    AS total,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_patients
FROM first_visit fv
JOIN patients p ON p.patient_id = fv.patient_id
GROUP BY age_group
ORDER BY age_group;


-- ============================================================
-- BQ-03: MONTHLY NEW vs RETURNING PATIENTS
-- Objective : Track acquisition vs retention
-- Grain     : month
-- Definitions:
--   New       = patient's first recorded visit in the dataset is in that month
--   Returning = visit in that month AND at least one visit before the month
-- Limitation: LEFT-CENSORING. History starts 1 Apr 2023, so early months
--   are dominated by "new" patients; FY2024-25 is the cleaner comparison.
-- ============================================================
WITH first_visit AS (
    SELECT patient_id, MIN(visit_date) AS first_visit_date
    FROM visits
    GROUP BY patient_id
),
monthly_patients AS (
    SELECT DISTINCT
        v.patient_id,
        DATE_TRUNC('month', v.visit_date)::date AS visit_month
    FROM visits v
)
SELECT
    mp.visit_month,
    COUNT(*)                                                             AS total_patients,
    COUNT(*) FILTER (WHERE DATE_TRUNC('month', fv.first_visit_date) = mp.visit_month) AS new_patients,
    COUNT(*) FILTER (WHERE fv.first_visit_date < mp.visit_month)         AS returning_patients,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fv.first_visit_date < mp.visit_month)
          / NULLIF(COUNT(*), 0), 1)                                      AS returning_pct
FROM monthly_patients mp
JOIN first_visit fv ON fv.patient_id = mp.patient_id
GROUP BY mp.visit_month
ORDER BY mp.visit_month;


-- ============================================================
-- BQ-04: REPEAT PATIENT RATE BY DEPARTMENT
-- Objective : Which departments see mostly returning patients
-- Grain     : department, period = FY2024-25 (cleaner period, left-censoring)
-- KPI       : Returning patients / Total patients
--   Total     = distinct patients with a FY2024-25 visit in the department
--   Returning = those patients with ANY visit (any department) before 1 Apr 2024
-- ============================================================
WITH first_visit AS (
    SELECT patient_id, MIN(visit_date) AS first_visit_date
    FROM visits
    GROUP BY patient_id
),
dept_patients_fy25 AS (
    SELECT DISTINCT department_id, patient_id
    FROM visits
    WHERE visit_date BETWEEN DATE '2024-04-01' AND DATE '2025-03-31'
)
SELECT
    d.department_name,
    COUNT(*)                                                                   AS total_patients,
    COUNT(*) FILTER (WHERE fv.first_visit_date < DATE '2024-04-01')            AS returning_patients,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fv.first_visit_date < DATE '2024-04-01')
          / NULLIF(COUNT(*), 0), 1)                                            AS repeat_rate_pct
FROM dept_patients_fy25 dp
JOIN first_visit fv ON fv.patient_id = dp.patient_id
JOIN departments d  ON d.department_id = dp.department_id
GROUP BY d.department_name
ORDER BY repeat_rate_pct DESC, d.department_name;

-- BQ-04 network rate (FY2024-25), same definition
WITH first_visit AS (
    SELECT patient_id, MIN(visit_date) AS first_visit_date
    FROM visits GROUP BY patient_id
),
fy25_patients AS (
    SELECT DISTINCT patient_id
    FROM visits
    WHERE visit_date BETWEEN DATE '2024-04-01' AND DATE '2025-03-31'
)
SELECT
    COUNT(*)                                                         AS total_patients,
    COUNT(*) FILTER (WHERE fv.first_visit_date < DATE '2024-04-01')  AS returning_patients,
    ROUND(100.0 * COUNT(*) FILTER (WHERE fv.first_visit_date < DATE '2024-04-01')
          / NULLIF(COUNT(*), 0), 1)                                  AS repeat_rate_pct
FROM fy25_patients fp
JOIN first_visit fv ON fv.patient_id = fp.patient_id;


-- ============================================================
-- BQ-05: MEDIAN INTERVAL BETWEEN VISITS
-- Objective : How soon do patients come back
-- Grain     : consecutive visit DATES per patient (same-day encounters,
--             e.g. ER then IP admission, are treated as one visit date)
-- Method    : LAG() gives the previous visit date; PERCENTILE_CONT(0.5)
--             gives the median (more robust than the mean for skewed gaps).
-- ============================================================
WITH visit_days AS (
    SELECT DISTINCT patient_id, visit_date
    FROM visits
),
gaps AS (
    SELECT
        patient_id,
        visit_date - LAG(visit_date) OVER (PARTITION BY patient_id ORDER BY visit_date) AS days_since_prev
    FROM visit_days
)
SELECT
    COUNT(*)                                                         AS return_intervals,
    COUNT(DISTINCT patient_id)                                       AS returning_patients,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_since_prev)     AS median_days,
    ROUND(AVG(days_since_prev), 1)                                   AS mean_days,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY days_since_prev)    AS p25_days,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY days_since_prev)    AS p75_days
FROM gaps
WHERE days_since_prev IS NOT NULL;      -- first visit has no previous visit


-- ============================================================
-- BQ-06: REVENUE SHARE BY PATIENT SPEND DECILE
-- Objective : How concentrated is revenue across patients
-- Grain     : patient spend decile (1 = highest spenders)
-- Revenue   : net_amount, all bills over the full window
-- Note      : ANALYTICAL SEGMENTATION ONLY - not a clinical or value
--             judgement and not an Apollo customer segment.
-- ============================================================
WITH patient_spend AS (
    SELECT
        v.patient_id,
        SUM(b.net_amount) AS total_spend
    FROM billing b
    JOIN visits v ON v.visit_id = b.visit_id
    GROUP BY v.patient_id
),
deciles AS (
    SELECT
        patient_id,
        total_spend,
        NTILE(10) OVER (ORDER BY total_spend DESC, patient_id) AS spend_decile
    FROM patient_spend
)
SELECT
    spend_decile,
    COUNT(*)                                                    AS patients,
    ROUND(MIN(total_spend), 0)                                  AS min_spend,
    ROUND(MAX(total_spend), 0)                                  AS max_spend,
    ROUND(SUM(total_spend), 0)                                  AS decile_revenue,
    ROUND(100.0 * SUM(total_spend) / SUM(SUM(total_spend)) OVER (), 1) AS pct_of_revenue
FROM deciles
GROUP BY spend_decile
ORDER BY spend_decile;


-- ============================================================
-- VALIDATION (patient analytics)
-- ============================================================
SELECT 'V13-1 Distinct patients with visits = patients table rows with visits' AS check_name,
       CASE WHEN (SELECT COUNT(DISTINCT patient_id) FROM visits)
               = (SELECT COUNT(*) FROM patients p
                  WHERE EXISTS (SELECT 1 FROM visits v WHERE v.patient_id = p.patient_id))
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V13-2 Spend deciles sum to billing net revenue',
       CASE WHEN (SELECT SUM(net_amount) FROM billing)
               = (SELECT SUM(s) FROM (SELECT SUM(b.net_amount) AS s
                                      FROM billing b JOIN visits v ON v.visit_id = b.visit_id
                                      GROUP BY v.patient_id) x)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V13-3 BQ-03 monthly new + returning = monthly total (all months)',
       CASE WHEN NOT EXISTS (
            SELECT 1
            FROM (SELECT DISTINCT patient_id, DATE_TRUNC('month', visit_date)::date AS m FROM visits) mp
            JOIN (SELECT patient_id, MIN(visit_date) AS fd FROM visits GROUP BY patient_id) fv USING (patient_id)
            GROUP BY mp.m
            HAVING COUNT(*) <> COUNT(*) FILTER (WHERE DATE_TRUNC('month', fv.fd) = mp.m)
                             + COUNT(*) FILTER (WHERE fv.fd < mp.m))
            THEN 'PASS' ELSE 'FAIL' END;

-- ============================================================
-- 15_doctor_analytics.sql   |  BQ-11 to BQ-15
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
-- Doctor attribution: attending doctor on the visit (visits.doctor_id).
-- Revenue basis: net_amount. Doctor names are synthetic.
-- Note (A-06): doctor workload in this dataset comes from a random
-- productivity weight per doctor, so doctor-level differences are
-- largely Assumption-driven.
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-11: TOP 3 DOCTORS BY NET REVENUE WITHIN EACH DEPARTMENT
-- Grain  : doctor (full window)
-- Method : doctor revenue -> RANK() partitioned by department -> keep rank <= 3
--          (RANK keeps ties; doctor_id breaks display order only)
-- ============================================================
WITH doctor_revenue AS (
    SELECT
        v.department_id,
        v.doctor_id,
        SUM(b.net_amount) AS net_revenue,
        COUNT(*)          AS visits
    FROM visits v
    JOIN billing b ON b.visit_id = v.visit_id
    GROUP BY v.department_id, v.doctor_id
),
ranked AS (
    SELECT
        dr.*,
        RANK() OVER (PARTITION BY dr.department_id ORDER BY dr.net_revenue DESC) AS dept_rank
    FROM doctor_revenue dr
)
SELECT
    d.department_name,
    r.dept_rank,
    doc.doctor_id,
    doc.doctor_name,
    f.facility_name,
    r.visits,
    ROUND(r.net_revenue, 0) AS net_revenue
FROM ranked r
JOIN departments d ON d.department_id = r.department_id
JOIN doctors doc   ON doc.doctor_id = r.doctor_id
JOIN facilities f  ON f.facility_id = doc.facility_id
WHERE r.dept_rank <= 3
ORDER BY d.department_name, r.dept_rank, doc.doctor_id;


-- ============================================================
-- BQ-12: DOCTORS WITH REVENUE ABOVE THEIR DEPARTMENT AVERAGE
-- Grain  : doctor
-- Method : CTE 1 doctor revenue; CTE 2 department average of doctor revenue;
--          JOIN and filter
-- ============================================================
WITH doctor_revenue AS (
    SELECT v.department_id, v.doctor_id, SUM(b.net_amount) AS net_revenue
    FROM visits v
    JOIN billing b ON b.visit_id = v.visit_id
    GROUP BY v.department_id, v.doctor_id
),
dept_average AS (
    SELECT department_id, AVG(net_revenue) AS avg_doctor_revenue, COUNT(*) AS doctors_in_dept
    FROM doctor_revenue
    GROUP BY department_id
)
SELECT
    d.department_name,
    doc.doctor_name,
    da.doctors_in_dept,
    ROUND(dr.net_revenue, 0)                                       AS doctor_revenue,
    ROUND(da.avg_doctor_revenue, 0)                                AS dept_avg_revenue,
    ROUND(100.0 * (dr.net_revenue - da.avg_doctor_revenue)
          / NULLIF(da.avg_doctor_revenue, 0), 1)                   AS pct_above_avg
FROM doctor_revenue dr
JOIN dept_average da ON da.department_id = dr.department_id
JOIN departments d   ON d.department_id = dr.department_id
JOIN doctors doc     ON doc.doctor_id = dr.doctor_id
WHERE dr.net_revenue > da.avg_doctor_revenue
ORDER BY d.department_name, pct_above_avg DESC;

-- BQ-12 summary: how many doctors are above their department average
WITH doctor_revenue AS (
    SELECT v.department_id, v.doctor_id, SUM(b.net_amount) AS net_revenue
    FROM visits v JOIN billing b ON b.visit_id = v.visit_id
    GROUP BY v.department_id, v.doctor_id
),
dept_average AS (
    SELECT department_id, AVG(net_revenue) AS avg_doctor_revenue
    FROM doctor_revenue GROUP BY department_id
)
SELECT
    COUNT(*)                                                       AS doctors,
    COUNT(*) FILTER (WHERE dr.net_revenue > da.avg_doctor_revenue) AS above_dept_average
FROM doctor_revenue dr
JOIN dept_average da ON da.department_id = dr.department_id;


-- ============================================================
-- BQ-13: AVERAGE MONTHLY VISIT LOAD PER DOCTOR
-- Grain  : doctor -> summarised by department
-- Method : visits / ACTIVE months. Active months run from the later of
--          (join month, Apr 2023) to Mar 2025, so doctors who joined
--          mid-window are not penalised.
-- ============================================================
WITH doctor_visits AS (
    SELECT doctor_id, COUNT(*) AS visits
    FROM visits
    GROUP BY doctor_id
),
doctor_load AS (
    SELECT
        doc.doctor_id,
        doc.department_id,
        COALESCE(dv.visits, 0) AS visits,
        -- months between start month and March 2025, inclusive
        (DATE_PART('year',  AGE(DATE '2025-03-01',
                                GREATEST(DATE_TRUNC('month', doc.join_date)::date, DATE '2023-04-01'))) * 12
       + DATE_PART('month', AGE(DATE '2025-03-01',
                                GREATEST(DATE_TRUNC('month', doc.join_date)::date, DATE '2023-04-01'))) + 1
        )::int AS active_months
    FROM doctors doc
    LEFT JOIN doctor_visits dv ON dv.doctor_id = doc.doctor_id
)
SELECT
    d.department_name,
    COUNT(*)                                                          AS doctors,
    SUM(dl.visits)                                                    AS visits,
    ROUND(AVG(dl.visits::numeric / NULLIF(dl.active_months, 0)), 1)   AS avg_monthly_visits_per_doctor,
    ROUND(MIN(dl.visits::numeric / NULLIF(dl.active_months, 0)), 1)   AS min_doctor,
    ROUND(MAX(dl.visits::numeric / NULLIF(dl.active_months, 0)), 1)   AS max_doctor
FROM doctor_load dl
JOIN departments d ON d.department_id = dl.department_id
GROUP BY d.department_name
ORDER BY avg_monthly_visits_per_doctor DESC, d.department_name;


-- ============================================================
-- BQ-14: REVENUE CONCENTRATION - TOP DOCTOR'S SHARE OF DEPARTMENT REVENUE
-- Grain  : department
-- Method : ROW_NUMBER picks one top doctor per department (doctor_id breaks ties)
-- Caution: departments with few doctors have high shares by construction,
--          and doctor productivity is a random generator weight (A-06).
-- ============================================================
WITH doctor_revenue AS (
    SELECT v.department_id, v.doctor_id, SUM(b.net_amount) AS net_revenue
    FROM visits v
    JOIN billing b ON b.visit_id = v.visit_id
    GROUP BY v.department_id, v.doctor_id
),
ranked AS (
    SELECT
        dr.*,
        ROW_NUMBER() OVER (PARTITION BY dr.department_id
                           ORDER BY dr.net_revenue DESC, dr.doctor_id) AS rn,
        SUM(dr.net_revenue) OVER (PARTITION BY dr.department_id)        AS dept_revenue,
        COUNT(*)            OVER (PARTITION BY dr.department_id)        AS doctors_in_dept
    FROM doctor_revenue dr
)
SELECT
    d.department_name,
    r.doctors_in_dept,
    ROUND(r.dept_revenue, 0)                                   AS dept_revenue,
    ROUND(r.net_revenue, 0)                                    AS top_doctor_revenue,
    ROUND(100.0 * r.net_revenue / NULLIF(r.dept_revenue, 0), 1) AS top_doctor_share_pct,
    ROUND(100.0 / r.doctors_in_dept, 1)                        AS equal_share_benchmark_pct
FROM ranked r
JOIN departments d ON d.department_id = r.department_id
WHERE r.rn = 1
ORDER BY top_doctor_share_pct DESC, d.department_name;


-- ============================================================
-- BQ-15: NO-SHOW RATE BY DOCTOR
-- Grain  : doctor (appointments table; all booked OP slots)
-- Rule   : doctors with >= 100 bookings only (threshold fixed before running)
-- Note   : DESCRIPTIVE ONLY. No-show status was generated independently of
--          doctor (D-02), so differences are expected sampling variation.
-- ============================================================
SELECT
    doc.doctor_name,
    d.department_name,
    COUNT(*)                                                              AS bookings,
    COUNT(*) FILTER (WHERE a.appointment_status = 'No-show')              AS no_shows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.appointment_status = 'No-show')
          / NULLIF(COUNT(*), 0), 1)                                       AS no_show_rate_pct
FROM appointments a
JOIN doctors doc   ON doc.doctor_id = a.doctor_id
JOIN departments d ON d.department_id = doc.department_id
GROUP BY doc.doctor_name, d.department_name, doc.doctor_id
HAVING COUNT(*) >= 100
ORDER BY no_show_rate_pct DESC, doc.doctor_id;

-- BQ-15 spread summary
WITH doctor_rates AS (
    SELECT doctor_id,
           COUNT(*) AS bookings,
           100.0 * COUNT(*) FILTER (WHERE appointment_status = 'No-show') / COUNT(*) AS rate
    FROM appointments
    GROUP BY doctor_id
    HAVING COUNT(*) >= 100
)
SELECT
    COUNT(*)                 AS doctors_included,
    ROUND(MIN(rate), 1)      AS min_rate_pct,
    ROUND(AVG(rate), 1)      AS avg_rate_pct,
    ROUND(MAX(rate), 1)      AS max_rate_pct,
    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'No-show') / COUNT(*), 1)
     FROM appointments)      AS network_rate_pct
FROM doctor_rates;


-- ============================================================
-- VALIDATION (doctor analytics)
-- ============================================================
SELECT 'V15-1 Sum of doctor revenue = billing net revenue' AS check_name,
       CASE WHEN (SELECT SUM(s) FROM (SELECT SUM(b.net_amount) s FROM visits v
                  JOIN billing b ON b.visit_id = v.visit_id GROUP BY v.doctor_id) x)
               = (SELECT SUM(net_amount) FROM billing)
            THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V15-2 Every department has exactly one top doctor in BQ-14 (14 rows)',
       CASE WHEN (SELECT COUNT(*) FROM (SELECT v.department_id,
                  ROW_NUMBER() OVER (PARTITION BY v.department_id ORDER BY SUM(b.net_amount) DESC, v.doctor_id) rn
                  FROM visits v JOIN billing b ON b.visit_id = v.visit_id
                  GROUP BY v.department_id, v.doctor_id) x WHERE rn = 1) = 14
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V15-3 Visits by doctor sum to total visits',
       CASE WHEN (SELECT SUM(c) FROM (SELECT COUNT(*) c FROM visits GROUP BY doctor_id) x)
               = (SELECT COUNT(*) FROM visits)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V15-4 Active months are between 1 and 24 for every doctor',
       CASE WHEN NOT EXISTS (
            SELECT 1 FROM doctors doc
            WHERE (DATE_PART('year',  AGE(DATE '2025-03-01', GREATEST(DATE_TRUNC('month', doc.join_date)::date, DATE '2023-04-01'))) * 12
                 + DATE_PART('month', AGE(DATE '2025-03-01', GREATEST(DATE_TRUNC('month', doc.join_date)::date, DATE '2023-04-01'))) + 1)
                  NOT BETWEEN 1 AND 24)
            THEN 'PASS' ELSE 'FAIL' END;

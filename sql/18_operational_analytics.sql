-- ============================================================
-- 18_operational_analytics.sql   |  BQ-25 to BQ-28
-- Synthetic portfolio dataset (PostgreSQL). Not Apollo data.
--
-- Bed capacity is a synthetic simulation parameter calibrated for analytical
-- coherence with the generated dataset volume. It does not represent actual
-- Apollo Hospitals facility capacity.
--
-- Patient-days: discharge_date - admission_date; a same-day IP stay
-- counts as 1 patient-day  ->  GREATEST(discharge_date - admission_date, 1)
-- A stay occupies a bed on nights admission_date .. admission_date + patient_days - 1.
-- ============================================================
SET search_path = processed;


-- ============================================================
-- BQ-25a: APPOINTMENT OUTCOMES - OVERALL
-- Grain  : appointment status (all booked OP slots)
-- ============================================================
SELECT
    appointment_status,
    COUNT(*)                                              AS appointments,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_of_bookings
FROM appointments
GROUP BY appointment_status
ORDER BY appointments DESC;

-- BQ-25b: CANCELLATION AND NO-SHOW RATE BY MONTH (scheduled month)
SELECT
    DATE_TRUNC('month', scheduled_datetime)::date                       AS scheduled_month,
    COUNT(*)                                                            AS bookings,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'Cancelled') / COUNT(*), 1) AS cancellation_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'No-show')   / COUNT(*), 1) AS no_show_rate_pct
FROM appointments
GROUP BY scheduled_month
ORDER BY scheduled_month;

-- BQ-25c: BY DEPARTMENT
SELECT
    d.department_name,
    COUNT(*)                                                            AS bookings,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.appointment_status = 'Cancelled') / COUNT(*), 1) AS cancellation_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.appointment_status = 'No-show')   / COUNT(*), 1) AS no_show_rate_pct
FROM appointments a
JOIN doctors doc   ON doc.doctor_id = a.doctor_id
JOIN departments d ON d.department_id = doc.department_id
GROUP BY d.department_name
ORDER BY no_show_rate_pct DESC, d.department_name;

-- BQ-25d: BY BOOKING CHANNEL ('Unknown' = channel not captured, DQ-06)
SELECT
    booking_channel,
    COUNT(*)                                                            AS bookings,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'Cancelled') / COUNT(*), 1) AS cancellation_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'No-show')   / COUNT(*), 1) AS no_show_rate_pct
FROM appointments
GROUP BY booking_channel
ORDER BY bookings DESC;


-- ============================================================
-- BQ-26: NO-SHOW RATE BY BOOKING LEAD-TIME BUCKET
-- Lead time = scheduled date - booking date (calendar days)
-- DESCRIPTIVE ASSOCIATION ONLY. No-show status was generated independently
-- of lead time (D-02); this analysis cannot show that lead time causes no-shows.
-- ============================================================
WITH appt AS (
    SELECT
        appointment_status,
        scheduled_datetime::date - booking_datetime::date AS lead_days
    FROM appointments
)
SELECT
    CASE
        WHEN lead_days = 0              THEN '1. Same day'
        WHEN lead_days BETWEEN 1 AND 3  THEN '2. 1-3 days'
        WHEN lead_days BETWEEN 4 AND 7  THEN '3. 4-7 days'
        WHEN lead_days BETWEEN 8 AND 14 THEN '4. 8-14 days'
        ELSE                                 '5. 15+ days'
    END                                                                 AS lead_time_bucket,
    COUNT(*)                                                            AS bookings,
    COUNT(*) FILTER (WHERE appointment_status = 'No-show')              AS no_shows,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'No-show') / COUNT(*), 1) AS no_show_rate_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE appointment_status = 'Cancelled') / COUNT(*), 1) AS cancellation_rate_pct
FROM appt
GROUP BY lead_time_bucket
ORDER BY lead_time_bucket;


-- ============================================================
-- BQ-27: AVERAGE LENGTH OF STAY (ALOS)
-- ALOS = total patient-days / IP discharges, attributed to discharge period
-- Grain: department, facility, and FY
-- ============================================================
SELECT
    d.department_name,
    COUNT(*)                                                                    AS ip_discharges,
    SUM(GREATEST(v.discharge_date - v.admission_date, 1))                       AS patient_days,
    ROUND(SUM(GREATEST(v.discharge_date - v.admission_date, 1))::numeric
          / NULLIF(COUNT(*), 0), 2)                                             AS alos_days
FROM visits v
JOIN departments d ON d.department_id = v.department_id
WHERE v.visit_type = 'IP'
GROUP BY d.department_name
ORDER BY alos_days DESC, d.department_name;

SELECT
    f.facility_name,
    f.city_tier,
    COUNT(*)                                                                    AS ip_discharges,
    ROUND(SUM(GREATEST(v.discharge_date - v.admission_date, 1))::numeric
          / NULLIF(COUNT(*), 0), 2)                                             AS alos_days
FROM visits v
JOIN facilities f ON f.facility_id = v.facility_id
WHERE v.visit_type = 'IP'
GROUP BY f.facility_name, f.city_tier
ORDER BY f.facility_name;

SELECT
    CASE WHEN discharge_date < DATE '2024-04-01' THEN 'FY2023-24' ELSE 'FY2024-25' END AS fy,
    COUNT(*)                                                                    AS ip_discharges,
    ROUND(SUM(GREATEST(discharge_date - admission_date, 1))::numeric
          / NULLIF(COUNT(*), 0), 2)                                             AS alos_days,
    COUNT(*) FILTER (WHERE discharge_date = admission_date)                     AS same_day_stays
FROM visits
WHERE visit_type = 'IP'
GROUP BY fy
ORDER BY fy;


-- ============================================================
-- BQ-28: BED OCCUPANCY AND PROJECT-DEFINED ARPOB BY FACILITY AND CITY TIER
--
-- Occupancy % = patient-days falling inside the FY / (operating beds x days in FY) x 100
--   Patient-days in FY for one stay (stays crossing 31 Mar are split):
--     GREATEST(0, LEAST(stay_end, fy_end + 1) - GREATEST(admission_date, fy_start))
--   where stay_end = admission_date + patient_days
--
-- Project-defined ARPOB implementation = IP net revenue / IP patient-days
--   (discharge-period attribution: numerator AND denominator use the same
--    stays - those discharged in the FY). Not Apollo's methodology; Apollo
--    historically reported ARPOB on a different basis and discontinued it
--    from Q1 FY26.
-- ============================================================
WITH fy AS (
    SELECT 'FY2023-24' AS fy, DATE '2023-04-01' AS fy_start, DATE '2024-03-31' AS fy_end
    UNION ALL
    SELECT 'FY2024-25', DATE '2024-04-01', DATE '2025-03-31'
),
ip_stays AS (
    SELECT
        v.facility_id,
        v.admission_date,
        v.discharge_date,
        GREATEST(v.discharge_date - v.admission_date, 1)                    AS patient_days,
        v.admission_date + GREATEST(v.discharge_date - v.admission_date, 1) AS stay_end,
        b.net_amount
    FROM visits v
    JOIN billing b ON b.visit_id = v.visit_id
    WHERE v.visit_type = 'IP'
),
facility_fy AS (
    SELECT
        fy.fy,
        s.facility_id,
        -- occupancy: patient-days physically inside the FY
        SUM(GREATEST(0, LEAST(s.stay_end, fy.fy_end + 1) - GREATEST(s.admission_date, fy.fy_start))) AS occupied_bed_days,
        -- ARPOB: stays discharged inside the FY
        SUM(s.net_amount)   FILTER (WHERE s.discharge_date BETWEEN fy.fy_start AND fy.fy_end)      AS ip_net_revenue,
        SUM(s.patient_days) FILTER (WHERE s.discharge_date BETWEEN fy.fy_start AND fy.fy_end)      AS discharged_patient_days,
        MAX(fy.fy_end - fy.fy_start + 1)                                                           AS days_in_fy
    FROM fy
    CROSS JOIN ip_stays s
    GROUP BY fy.fy, s.facility_id
)
SELECT
    ff.fy,
    f.facility_name,
    f.city_tier,
    f.operating_bed_count,
    ff.occupied_bed_days,
    f.operating_bed_count * ff.days_in_fy                                         AS available_bed_days,
    ROUND(100.0 * ff.occupied_bed_days / NULLIF(f.operating_bed_count * ff.days_in_fy, 0), 1) AS occupancy_pct,
    ROUND(ff.ip_net_revenue / NULLIF(ff.discharged_patient_days, 0), 0)          AS project_arpob_inr
FROM facility_fy ff
JOIN facilities f ON f.facility_id = ff.facility_id
ORDER BY ff.fy, f.facility_name;

-- BQ-28 by city tier (tier = SUM of patient-days / SUM of bed-days; never an
-- average of facility percentages)
WITH fy AS (
    SELECT 'FY2023-24' AS fy, DATE '2023-04-01' AS fy_start, DATE '2024-03-31' AS fy_end
    UNION ALL
    SELECT 'FY2024-25', DATE '2024-04-01', DATE '2025-03-31'
),
ip_stays AS (
    SELECT v.facility_id, v.admission_date, v.discharge_date,
           GREATEST(v.discharge_date - v.admission_date, 1)                    AS patient_days,
           v.admission_date + GREATEST(v.discharge_date - v.admission_date, 1) AS stay_end,
           b.net_amount
    FROM visits v JOIN billing b ON b.visit_id = v.visit_id
    WHERE v.visit_type = 'IP'
),
tier_beds AS (
    SELECT city_tier, SUM(operating_bed_count) AS beds
    FROM facilities GROUP BY city_tier
),
tier_fy AS (
    SELECT
        fy.fy,
        f.city_tier,
        SUM(GREATEST(0, LEAST(s.stay_end, fy.fy_end + 1) - GREATEST(s.admission_date, fy.fy_start))) AS occupied_bed_days,
        SUM(s.net_amount)   FILTER (WHERE s.discharge_date BETWEEN fy.fy_start AND fy.fy_end)      AS ip_net_revenue,
        SUM(s.patient_days) FILTER (WHERE s.discharge_date BETWEEN fy.fy_start AND fy.fy_end)      AS discharged_patient_days,
        MAX(fy.fy_end - fy.fy_start + 1)                                                           AS days_in_fy
    FROM fy
    CROSS JOIN ip_stays s
    JOIN facilities f ON f.facility_id = s.facility_id
    GROUP BY fy.fy, f.city_tier
)
SELECT
    t.fy,
    t.city_tier,
    tb.beds,
    ROUND(100.0 * t.occupied_bed_days / NULLIF(tb.beds * t.days_in_fy, 0), 1) AS occupancy_pct,
    ROUND(t.ip_net_revenue / NULLIF(t.discharged_patient_days, 0), 0)         AS project_arpob_inr
FROM tier_fy t
JOIN tier_beds tb ON tb.city_tier = t.city_tier
ORDER BY t.fy, t.city_tier;


-- ============================================================
-- VALIDATION (operational analytics)
-- ============================================================
SELECT 'V18-1 Appointment statuses sum to total bookings' AS check_name,
       CASE WHEN (SELECT SUM(c) FROM (SELECT COUNT(*) c FROM appointments GROUP BY appointment_status) x)
               = (SELECT COUNT(*) FROM appointments) THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 'V18-2 Lead-time buckets cover every booking (no negative lead time)',
       CASE WHEN NOT EXISTS (SELECT 1 FROM appointments
                             WHERE scheduled_datetime::date - booking_datetime::date < 0)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V18-3 Occupancy <= 100% for every facility-day (daily census vs beds)',
       CASE WHEN NOT EXISTS (
            SELECT 1
            FROM (SELECT v.facility_id, d::date AS day, COUNT(*) AS census
                  FROM visits v
                  CROSS JOIN LATERAL generate_series(v.admission_date,
                        v.admission_date + GREATEST(v.discharge_date - v.admission_date, 1) - 1,
                        INTERVAL '1 day') d
                  WHERE v.visit_type = 'IP'
                  GROUP BY v.facility_id, d::date) c
            JOIN facilities f ON f.facility_id = c.facility_id
            WHERE c.census > f.operating_bed_count)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V18-4 FY-allocated occupied bed-days sum to total patient-days',
       CASE WHEN (SELECT SUM(GREATEST(0, LEAST(v.admission_date + GREATEST(v.discharge_date - v.admission_date, 1), fy_end + 1)
                                          - GREATEST(v.admission_date, fy_start)))
                  FROM visits v
                  CROSS JOIN (VALUES (DATE '2023-04-01', DATE '2024-03-31'),
                                     (DATE '2024-04-01', DATE '2025-03-31')) fy(fy_start, fy_end)
                  WHERE v.visit_type = 'IP')
               = (SELECT SUM(GREATEST(discharge_date - admission_date, 1)) FROM visits WHERE visit_type = 'IP')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'V18-5 ARPOB numerator and denominator cover the same IP stays (every IP visit has one bill)',
       CASE WHEN (SELECT COUNT(*) FROM visits v JOIN billing b ON b.visit_id = v.visit_id WHERE v.visit_type = 'IP')
               = (SELECT COUNT(*) FROM visits WHERE visit_type = 'IP')
            THEN 'PASS' ELSE 'FAIL' END;

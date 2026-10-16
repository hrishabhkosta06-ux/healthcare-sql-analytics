/* =============================================================================
   04_generate_appointments.sql   (Phase 4)
   Generates raw.appointments (booked OP slots).

   Design (A-05, A-16, A-17, D-02, D-04 in documentation/generation_assumptions.md):
   - Per-patient appointment count: exponential draw, capped; dates spread
     forward from the patient's anchor with exponential gaps.
   - Facility: home facility 85%, otherwise weighted pick of another facility.
   - Department: patient's primary department 70% (if available + eligible),
     otherwise weighted pick among available, eligible departments.
   - Doctor: weighted (productivity) pick among doctors in that facility and
     department who had joined by the booking date.
   - Status (Completed / Cancelled / No-show) is drawn INDEPENDENTLY of lead
     time, doctor, department, facility and patient (D-02).
   - Lead time drawn from fixed buckets; booking floored at 2023-04-01 (D-04).
   Weighted picks use the exponential-race method:
       pick the candidate with the smallest  -ln(1-u) / weight.
   Deliberate DQ (A-22): DQ-04 channel label variants, DQ-05 NULL
   cancellation_reason, DQ-06 NULL booking_channel. Injected at the end.
   ========================================================================== */

DROP TABLE IF EXISTS tmp_pat;
CREATE TEMP TABLE tmp_pat AS
SELECT p.patient_id, p.gender, p.date_of_birth AS dob,
       p.registration_date AS anchor, p.registration_facility_id AS home_facility
FROM raw.patients p;

-- 1. Primary department per patient (weighted, available at home, eligible at anchor)
DROP TABLE IF EXISTS tmp_primary;
CREATE TEMP TABLE tmp_primary AS
SELECT t.patient_id, pick.department_id AS primary_dept
FROM tmp_pat t
CROSS JOIN LATERAL (
    SELECT dp.department_id
    FROM gen.v_dept_params dp
    JOIN gen.v_available_dept av
      ON av.department_id = dp.department_id AND av.facility_id = t.home_facility
    WHERE dp.op_weight > 0
      AND gen.dept_eligible(dp.department_id, t.dob, t.gender, t.anchor)
    ORDER BY -ln(1 - gen.u('apt:prim:' || t.patient_id || ':' || dp.department_id)) / dp.op_weight,
             dp.department_id
    LIMIT 1
) pick;

-- 2. Appointment skeleton: count, dates, slot, lead time
DROP TABLE IF EXISTS tmp_appt;
CREATE TEMP TABLE tmp_appt AS
WITH counts AS (
    SELECT t.*, pr.primary_dept,
           least(floor(gen.expo('apt:k:' || t.patient_id, p.appt_count_mean))::int,
                 p.appt_count_cap) AS k
    FROM tmp_pat t
    JOIN tmp_primary pr USING (patient_id)
    CROSS JOIN gen.v_params p
),
series AS (
    SELECT c.*, j,
           CASE WHEN j = 1 THEN gen.ri('apt:gap:' || c.patient_id || ':1', 0, 6)
                ELSE 1 + floor(gen.expo('apt:gap:' || c.patient_id || ':' || j,
                                        (SELECT appt_gap_mean_days FROM gen.v_params)))::int
           END AS gap
    FROM counts c
    CROSS JOIN LATERAL generate_series(1, c.k) AS j
),
dated AS (
    SELECT s.*,
           s.anchor + sum(s.gap) OVER (PARTITION BY s.patient_id ORDER BY s.j)::int AS raw_date
    FROM series s
),
shifted AS (     -- clinics closed on Sunday: move to Monday
    SELECT d.*,
           CASE WHEN extract(dow FROM d.raw_date) = 0 THEN d.raw_date + 1 ELSE d.raw_date END
               AS sched_date
    FROM dated d
)
SELECT sh.patient_id, sh.j, sh.gender, sh.dob, sh.home_facility, sh.primary_dept,
       sh.sched_date,
       sh.sched_date + time '09:00'
           + make_interval(mins => 15 * gen.ri('apt:slot:' || sh.patient_id || ':' || sh.j, 0, 31))
           AS scheduled_datetime,
       gen.u('apt:lead:' || sh.patient_id || ':' || sh.j) AS u_lead
FROM shifted sh
WHERE sh.sched_date <= (SELECT window_end FROM gen.v_params);

-- 3. Facility choice
ALTER TABLE tmp_appt ADD COLUMN facility_id varchar(6);
UPDATE tmp_appt a
SET facility_id = CASE
        WHEN gen.u('apt:fachome:' || a.patient_id || ':' || a.j) < (SELECT home_facility_share FROM gen.v_params)
        THEN a.home_facility
        ELSE (SELECT fp.facility_id FROM gen.v_facility_params fp
              WHERE fp.facility_id <> a.home_facility
              ORDER BY -ln(1 - gen.u('apt:fac:' || a.patient_id || ':' || a.j || ':' || fp.facility_id))
                       / fp.home_weight, fp.facility_id
              LIMIT 1)
    END;

-- 4. Lead time -> booking datetime (floored at window start, D-04)
ALTER TABLE tmp_appt ADD COLUMN booking_datetime timestamp;
UPDATE tmp_appt a
SET booking_datetime = greatest(
        TIMESTAMP '2023-04-01 00:00:00',
        CASE
          WHEN a.u_lead < 0.15 THEN    -- same day: 30-180 minutes before the slot
               a.scheduled_datetime
               - make_interval(mins => 30 + gen.ri('apt:bkmin:' || a.patient_id || ':' || a.j, 0, 150))
          ELSE (a.sched_date - CASE
                    WHEN a.u_lead < 0.50 THEN gen.ri('apt:L:' || a.patient_id || ':' || a.j, 1, 3)
                    WHEN a.u_lead < 0.75 THEN gen.ri('apt:L:' || a.patient_id || ':' || a.j, 4, 7)
                    WHEN a.u_lead < 0.90 THEN gen.ri('apt:L:' || a.patient_id || ':' || a.j, 8, 14)
                    ELSE                      gen.ri('apt:L:' || a.patient_id || ':' || a.j, 15, 60)
                END) + time '08:00'
               + make_interval(mins => gen.ri('apt:bktime:' || a.patient_id || ':' || a.j, 0, 719))
        END);

-- 5. Department + doctor choice
DROP TABLE IF EXISTS tmp_appt2;
CREATE TEMP TABLE tmp_appt2 AS
SELECT a.*, dep.department_id, doc.doctor_id
FROM tmp_appt a
CROSS JOIN LATERAL (
    SELECT CASE
             WHEN gen.u('apt:useprim:' || a.patient_id || ':' || a.j)
                    < (SELECT primary_dept_share FROM gen.v_params)
              AND EXISTS (SELECT 1 FROM gen.v_available_dept av
                          WHERE av.facility_id = a.facility_id AND av.department_id = a.primary_dept)
              AND gen.dept_eligible(a.primary_dept, a.dob, a.gender, a.sched_date)
             THEN a.primary_dept
             ELSE (SELECT dp.department_id
                   FROM gen.v_dept_params dp
                   JOIN gen.v_available_dept av
                     ON av.department_id = dp.department_id AND av.facility_id = a.facility_id
                   WHERE dp.op_weight > 0
                     AND gen.dept_eligible(dp.department_id, a.dob, a.gender, a.sched_date)
                   ORDER BY -ln(1 - gen.u('apt:dep:' || a.patient_id || ':' || a.j || ':' || dp.department_id))
                            / dp.op_weight, dp.department_id
                   LIMIT 1)
           END AS department_id
) dep
CROSS JOIN LATERAL (
    SELECT dw.doctor_id
    FROM gen.v_doctor_weight dw
    WHERE dw.facility_id = a.facility_id
      AND dw.department_id = dep.department_id
      AND dw.join_date <= a.booking_datetime::date
    ORDER BY -ln(1 - gen.u('apt:doc:' || a.patient_id || ':' || a.j || ':' || dw.doctor_id)) / dw.weight,
             dw.doctor_id
    LIMIT 1
) doc;

-- 6. Insert with independent status, reason, channel
INSERT INTO raw.appointments
SELECT 'APT' || lpad(row_number() OVER (ORDER BY a.scheduled_datetime, a.patient_id, a.j)::text, 6, '0'),
       a.patient_id,
       a.doctor_id,
       a.facility_id,
       a.booking_datetime,
       a.scheduled_datetime,
       s.status,
       CASE WHEN s.status = 'Cancelled' THEN
            CASE WHEN gen.u('apt:why:' || a.patient_id || ':' || a.j) < 0.35 THEN 'Patient Request'
                 WHEN gen.u('apt:why:' || a.patient_id || ':' || a.j) < 0.65 THEN 'Rescheduled by Patient'
                 WHEN gen.u('apt:why:' || a.patient_id || ':' || a.j) < 0.80 THEN 'Doctor Unavailable'
                 WHEN gen.u('apt:why:' || a.patient_id || ':' || a.j) < 0.85 THEN 'Financial'
                 ELSE 'Other' END
       END,
       CASE WHEN gen.u('apt:ch:' || a.patient_id || ':' || a.j) < 0.35 THEN 'Phone'
            WHEN gen.u('apt:ch:' || a.patient_id || ':' || a.j) < 0.55 THEN 'Website'
            WHEN gen.u('apt:ch:' || a.patient_id || ':' || a.j) < 0.85 THEN 'Mobile App'
            ELSE 'Front Desk' END
FROM tmp_appt2 a
CROSS JOIN LATERAL (
    SELECT CASE
             WHEN gen.u('apt:status:' || a.patient_id || ':' || a.j) < p.p_completed THEN 'Completed'
             WHEN gen.u('apt:status:' || a.patient_id || ':' || a.j) < p.p_completed + p.p_cancelled THEN 'Cancelled'
             ELSE 'No-show' END AS status
    FROM gen.v_params p
) s;

/* ---------------------------------------------------------------------------
   7. Deliberate data-quality issues (raw only; keys untouched)
   ------------------------------------------------------------------------ */
-- DQ-05: ~10% of cancelled appointments lose their reason
UPDATE raw.appointments
SET cancellation_reason = NULL
WHERE appointment_status = 'Cancelled'
  AND gen.u('dq05:' || appointment_id) < 0.10;

-- DQ-06: ~3% of appointments have no booking channel captured
UPDATE raw.appointments
SET booking_channel = NULL
WHERE gen.u('dq06:' || appointment_id) < 0.03;

-- DQ-04: ~4% of remaining channel labels written inconsistently
UPDATE raw.appointments
SET booking_channel = CASE booking_channel
        WHEN 'Phone'      THEN gen.pick('dq04v:' || appointment_id, ARRAY['phone',' Phone','PHONE'])
        WHEN 'Website'    THEN gen.pick('dq04v:' || appointment_id, ARRAY['website','Web','WEBSITE'])
        WHEN 'Mobile App' THEN gen.pick('dq04v:' || appointment_id, ARRAY['mobile app','App','MOBILE APP'])
        WHEN 'Front Desk' THEN gen.pick('dq04v:' || appointment_id, ARRAY['front desk','Frontdesk','Front Desk '])
    END
WHERE booking_channel IS NOT NULL
  AND gen.u('dq04:' || appointment_id) < 0.04;

SELECT count(*) AS appointments,
       count(*) FILTER (WHERE appointment_status = 'Completed') AS completed,
       count(*) FILTER (WHERE appointment_status = 'Cancelled') AS cancelled,
       count(*) FILTER (WHERE appointment_status = 'No-show')   AS no_show,
       count(DISTINCT patient_id) AS patients_with_appointments
FROM raw.appointments;

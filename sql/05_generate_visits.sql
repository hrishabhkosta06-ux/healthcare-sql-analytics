/* =============================================================================
   05_generate_visits.sql   (Phase 5)
   Generates raw.visits (OP, IP, ER, Day-care), then finalises patient
   registration, then injects patient-level data-quality issues.

   KEY DESIGN: BED-TIMELINE IP GENERATION (D-01 capacity rule)
   Each operating bed is a timeline. Stays are laid end-to-end on that
   timeline:  next_admission = admission + patient_days + idle_gap.
   A bed therefore never holds two patients on the same night, so
       daily IP census <= operating_bed_count
   holds BY CONSTRUCTION. No admission ever needs to be rejected or shifted for
   capacity; the count of capacity adjustments is therefore 0 and is reported.
   Occupancy is driven by the documented idle-gap parameter (A-18), so
   occupancy results are Assumption-driven (CR-03).

   Patient assignment rules for IP stays:
   - age/sex eligibility for the department on the admission date
   - patient's anchor (provisional registration) on or before admission
   - no Completed OP appointment strictly inside (admission, discharge)  [IC-01]
   - no overlap with the patient's other stays  [validation check I01]
   - A-21: a share of non-ER stays prefer a patient who had a Completed OP
     appointment in the same facility+department 0-30 days before admission
     (OP status itself is never altered; selection only).
   Unassignable stays are dropped and COUNTED.
   ========================================================================== */

/* ---------------------------------------------------------------------------
   A. Patient pool ordered by anchor (for "random patient registered by date d")
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_pool;
CREATE TEMP TABLE tmp_pool AS
SELECT row_number() OVER (ORDER BY registration_date, patient_id)::int AS rn,
       patient_id, registration_date AS anchor, date_of_birth AS dob, gender,
       registration_facility_id AS home_facility
FROM raw.patients;
CREATE UNIQUE INDEX ON tmp_pool (rn);
CREATE INDEX ON tmp_pool (patient_id);

DROP TABLE IF EXISTS tmp_nle;          -- number of pool patients with anchor <= d
CREATE TEMP TABLE tmp_nle AS
SELECT d::date AS d,
       (SELECT count(*) FROM tmp_pool p WHERE p.anchor <= d::date)::int AS n
FROM generate_series(DATE '2023-04-01', DATE '2025-03-31', interval '1 day') AS d;
CREATE UNIQUE INDEX ON tmp_nle (d);

/* ---------------------------------------------------------------------------
   B. IP stays on bed timelines
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_stay;
CREATE TEMP TABLE tmp_stay AS
WITH beds AS (
    SELECT fp.facility_id, fp.bed_gap_mean_days, b
    FROM gen.v_facility_params fp
    CROSS JOIN LATERAL generate_series(1, fp.operating_bed_count) AS b
),
slots AS (
    SELECT bd.facility_id, bd.b, k, bd.bed_gap_mean_days,
           bd.facility_id || '-' || bd.b || '-' || k AS stay_key
    FROM beds bd
    CROSS JOIN generate_series(1, 200) AS k
),
with_dept AS (
    SELECT s.*, dep.department_id, dep.los_mean
    FROM slots s
    CROSS JOIN LATERAL (
        SELECT dp.department_id, dp.los_mean
        FROM gen.v_dept_params dp
        JOIN gen.v_available_dept av
          ON av.department_id = dp.department_id AND av.facility_id = s.facility_id
        WHERE dp.ip_weight > 0
        ORDER BY -ln(1 - gen.u('ip:dep:' || s.stay_key || ':' || dp.department_id)) / dp.ip_weight,
                 dp.department_id
        LIMIT 1
    ) dep
),
with_los AS (
    SELECT w.*,
           CASE WHEN gen.u('ip:sameday:' || w.stay_key) < (SELECT same_day_ip_share FROM gen.v_params)
                THEN 0
                ELSE least(1 + floor(gen.expo('ip:los:' || w.stay_key, w.los_mean - 1))::int,
                           (SELECT los_cap_days FROM gen.v_params))
           END AS los,
           floor(gen.expo('ip:gap:' || w.stay_key, w.bed_gap_mean_days))::int AS idle_gap,
           gen.ri('ip:offset:' || w.facility_id || '-' || w.b, 0, 5)          AS bed_offset
    FROM with_dept w
),
timeline AS (
    SELECT l.*,
           greatest(l.los, 1) AS patient_days,
           DATE '2023-04-01' + l.bed_offset
             + coalesce(sum(greatest(l.los, 1) + l.idle_gap)
                        OVER (PARTITION BY l.facility_id, l.b ORDER BY l.k
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::int
             AS admission_date
    FROM with_los l
)
SELECT t.stay_key, t.facility_id, t.b AS bed_no, t.k, t.department_id, t.los, t.patient_days,
       t.admission_date,
       t.admission_date + t.los          AS discharge_date,
       t.admission_date + t.patient_days AS end_excl,       -- half-open occupancy end
       CASE WHEN gen.u('ip:disp:' || t.stay_key) < 0.95 THEN 'Discharged'
            WHEN gen.u('ip:disp:' || t.stay_key) < 0.98 THEN 'Transferred'
            ELSE 'LAMA' END                AS discharge_status,
       NULL::varchar(6)                    AS doctor_id,
       gen.u('ip:er:' || t.stay_key) < (SELECT er_origin_share FROM gen.v_params) AS is_er_origin,
       NULL::boolean                       AS is_referred,
       NULL::varchar(8)                    AS patient_id,
       NULL::int                           AS assign_round
FROM timeline t
WHERE t.admission_date + t.los <= DATE '2025-03-31';     -- no open stays at cutoff
ALTER TABLE tmp_stay ADD PRIMARY KEY (stay_key);
CREATE INDEX ON tmp_stay (patient_id);

-- Admitting doctor: weighted pick among doctors of that facility+department joined by admission
UPDATE tmp_stay s
SET doctor_id = (
    SELECT dw.doctor_id FROM gen.v_doctor_weight dw
    WHERE dw.facility_id = s.facility_id AND dw.department_id = s.department_id
      AND dw.join_date <= s.admission_date
    ORDER BY -ln(1 - gen.u('ip:doc:' || s.stay_key || ':' || dw.doctor_id)) / dw.weight, dw.doctor_id
    LIMIT 1);

-- A-21 referral flag (only for non-ER-origin stays)
UPDATE tmp_stay s
SET is_referred = NOT s.is_er_origin
              AND gen.u('ip:ref:' || s.stay_key) <
                  CASE WHEN dp.department_category = 'Surgical'
                       THEN (SELECT op_referred_share_surgical FROM gen.v_params)
                       ELSE (SELECT op_referred_share_medical  FROM gen.v_params) END
FROM gen.v_dept_params dp
WHERE dp.department_id = s.department_id;

/* ---------------------------------------------------------------------------
   C. Assign patients to stays in rounds (set-based inside a PL/pgSQL loop).
   Each round: (1) referred stays try a recent OP patient of the same
   facility+department; (2) remaining stays draw up to 40 random pool patients;
   (3) same-round collisions (one patient, two overlapping stays) keep the
   earliest admission and release the rest for the next round.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_completed_op;
CREATE TEMP TABLE tmp_completed_op AS
SELECT a.patient_id, a.facility_id, d.department_id, a.scheduled_datetime::date AS op_date
FROM raw.appointments a
JOIN raw.doctors d USING (doctor_id)
WHERE a.appointment_status = 'Completed';
CREATE INDEX ON tmp_completed_op (patient_id, op_date);
CREATE INDEX ON tmp_completed_op (facility_id, department_id, op_date);

DO $$
DECLARE r int;
BEGIN
  FOR r IN 1..6 LOOP

    -- (1) referred stays: recent OP patient in same facility + department
    UPDATE tmp_stay s
    SET patient_id = c.patient_id, assign_round = r
    FROM (
        SELECT DISTINCT ON (s2.stay_key) s2.stay_key, op.patient_id
        FROM tmp_stay s2
        JOIN tmp_completed_op op
          ON op.facility_id = s2.facility_id
         AND op.department_id = s2.department_id
         AND op.op_date BETWEEN s2.admission_date - 30 AND s2.admission_date
        JOIN tmp_pool p ON p.patient_id = op.patient_id
        WHERE s2.patient_id IS NULL AND s2.is_referred
          AND p.anchor <= s2.admission_date
          AND gen.dept_eligible(s2.department_id, p.dob, p.gender, s2.admission_date)
          AND NOT EXISTS (SELECT 1 FROM tmp_completed_op x
                          WHERE x.patient_id = op.patient_id
                            AND x.op_date > s2.admission_date AND x.op_date < s2.discharge_date)
          AND NOT EXISTS (SELECT 1 FROM tmp_stay o
                          WHERE o.patient_id = op.patient_id
                            AND o.admission_date < s2.end_excl AND s2.admission_date < o.end_excl)
        ORDER BY s2.stay_key, gen.u('ip:refpick:' || r || ':' || s2.stay_key || ':' || op.patient_id),
                 op.patient_id
    ) c
    WHERE s.stay_key = c.stay_key;

    -- (2) all still-unassigned stays: up to 40 random tries from the pool
    UPDATE tmp_stay s
    SET patient_id = c.patient_id, assign_round = r
    FROM (
        SELECT DISTINCT ON (s2.stay_key) s2.stay_key, p.patient_id
        FROM tmp_stay s2
        JOIN tmp_nle nl ON nl.d = s2.admission_date
        CROSS JOIN generate_series(1, 40) AS t
        JOIN tmp_pool p
          ON p.rn = 1 + floor(gen.u('ip:try:' || r || ':' || s2.stay_key || ':' || t) * nl.n)::int
        WHERE s2.patient_id IS NULL
          AND nl.n > 0
          AND gen.dept_eligible(s2.department_id, p.dob, p.gender, s2.admission_date)
          AND NOT EXISTS (SELECT 1 FROM tmp_completed_op x
                          WHERE x.patient_id = p.patient_id
                            AND x.op_date > s2.admission_date AND x.op_date < s2.discharge_date)
          AND NOT EXISTS (SELECT 1 FROM tmp_stay o
                          WHERE o.patient_id = p.patient_id
                            AND o.admission_date < s2.end_excl AND s2.admission_date < o.end_excl)
        ORDER BY s2.stay_key, t
    ) c
    WHERE s.stay_key = c.stay_key;

    -- (3) release same-round collisions (keep earliest admission per patient overlap)
    UPDATE tmp_stay s
    SET patient_id = NULL, assign_round = NULL
    WHERE s.assign_round = r
      AND EXISTS (SELECT 1 FROM tmp_stay o
                  WHERE o.patient_id = s.patient_id
                    AND o.stay_key <> s.stay_key
                    AND o.admission_date < s.end_excl AND s.admission_date < o.end_excl
                    AND (o.admission_date, o.stay_key) < (s.admission_date, s.stay_key));
  END LOOP;
END $$;

/* ---------------------------------------------------------------------------
   D. Non-IP encounter candidates
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_vis;
CREATE TEMP TABLE tmp_vis (
    src_key        text PRIMARY KEY,
    patient_id     varchar(8),
    doctor_id      varchar(6),
    department_id  varchar(5),
    facility_id    varchar(6),
    appointment_id varchar(10),
    visit_type     varchar(10),
    visit_date     date,
    admission_date date,
    discharge_date date,
    discharge_status varchar(20)
);

-- D1. OP visits from Completed appointments (exactly one each)
INSERT INTO tmp_vis
SELECT 'OPA:' || a.appointment_id, a.patient_id, a.doctor_id, d.department_id, a.facility_id,
       a.appointment_id, 'OP', a.scheduled_datetime::date, NULL, NULL, NULL
FROM raw.appointments a
JOIN raw.doctors d USING (doctor_id)
WHERE a.appointment_status = 'Completed';

-- D2. IP stays that received a patient
INSERT INTO tmp_vis
SELECT 'IP:' || s.stay_key, s.patient_id, s.doctor_id, s.department_id, s.facility_id,
       NULL, 'IP', s.admission_date, s.admission_date, s.discharge_date, s.discharge_status
FROM tmp_stay s
WHERE s.patient_id IS NOT NULL;

-- D3. ER visits on the admission day of ER-origin stays
INSERT INTO tmp_vis
SELECT 'ERX:' || s.stay_key, s.patient_id, er.doctor_id, 'DEP01', s.facility_id,
       NULL, 'ER', s.admission_date, NULL, NULL, NULL
FROM tmp_stay s
CROSS JOIN LATERAL (
    SELECT dw.doctor_id FROM gen.v_doctor_weight dw
    WHERE dw.facility_id = s.facility_id AND dw.department_id = 'DEP01'
      AND dw.join_date <= s.admission_date
    ORDER BY -ln(1 - gen.u('erx:doc:' || s.stay_key || ':' || dw.doctor_id)) / dw.weight, dw.doctor_id
    LIMIT 1) er
WHERE s.patient_id IS NOT NULL AND s.is_er_origin;

-- Common candidate frame for walk-in OP, random ER and Day-care
DROP TABLE IF EXISTS tmp_cand;
CREATE TEMP TABLE tmp_cand AS
WITH frame AS (
    SELECT 'WI' AS kind, n FROM generate_series(1, (SELECT walkin_op_candidates FROM gen.v_params)) n
    UNION ALL
    SELECT 'ER', n FROM generate_series(1, (SELECT er_candidates FROM gen.v_params)) n
    UNION ALL
    SELECT 'DC', n FROM generate_series(1, (SELECT daycare_candidates FROM gen.v_params)) n
),
dated AS (
    SELECT f.kind, f.n, f.kind || ':' || f.n AS ckey,
           DATE '2023-04-01' + gen.ri('cand:date:' || f.kind || ':' || f.n, 0, 730) AS d0
    FROM frame f
)
SELECT ckey, kind, n,
       CASE WHEN kind <> 'ER' AND extract(dow FROM d0) = 0 THEN d0 + 1 ELSE d0 END AS vdate
FROM dated;
DELETE FROM tmp_cand WHERE vdate > DATE '2025-03-31';

-- choose patient (anchor <= date); Day-care requires a patient eligible for at least
-- one day-care department at the chosen facility, so up to 10 tries are allowed
DROP TABLE IF EXISTS tmp_cand2;
CREATE TEMP TABLE tmp_cand2 AS
SELECT c.*, pk.patient_id, pk.dob, pk.gender, pk.home_facility
FROM tmp_cand c
JOIN tmp_nle nl ON nl.d = c.vdate
CROSS JOIN LATERAL (
    SELECT p.patient_id, p.dob, p.gender, p.home_facility
    FROM generate_series(1, 10) t
    JOIN tmp_pool p ON p.rn = 1 + floor(gen.u('cand:pat:' || c.ckey || ':' || t) * nl.n)::int
    WHERE nl.n > 0
      AND (c.kind <> 'DC' OR date_part('year', age(c.vdate, p.dob)) >= 18)
    ORDER BY t
    LIMIT 1
) pk;

ALTER TABLE tmp_cand2 ADD COLUMN facility_id varchar(6);
UPDATE tmp_cand2 c
SET facility_id = CASE
        WHEN gen.u('cand:fachome:' || c.ckey) < (SELECT home_facility_share FROM gen.v_params)
        THEN c.home_facility
        ELSE (SELECT fp.facility_id FROM gen.v_facility_params fp
              WHERE fp.facility_id <> c.home_facility
              ORDER BY -ln(1 - gen.u('cand:fac:' || c.ckey || ':' || fp.facility_id)) / fp.home_weight,
                       fp.facility_id
              LIMIT 1) END;

INSERT INTO tmp_vis
SELECT 'C' || c.ckey, c.patient_id, doc.doctor_id, dep.department_id, c.facility_id,
       NULL,
       CASE c.kind WHEN 'WI' THEN 'OP' WHEN 'ER' THEN 'ER' ELSE 'Day-care' END,
       c.vdate, NULL, NULL, NULL
FROM tmp_cand2 c
CROSS JOIN LATERAL (
    SELECT dp.department_id
    FROM gen.v_dept_params dp
    JOIN gen.v_available_dept av
      ON av.department_id = dp.department_id AND av.facility_id = c.facility_id
    WHERE CASE c.kind WHEN 'ER' THEN dp.department_id = 'DEP01'
                      WHEN 'WI' THEN dp.op_weight > 0
                      ELSE dp.dc_capable END
      AND gen.dept_eligible(dp.department_id, c.dob, c.gender, c.vdate)
    ORDER BY CASE WHEN c.kind = 'ER' THEN 0
                  ELSE -ln(1 - gen.u('cand:dep:' || c.ckey || ':' || dp.department_id))
                       / greatest(dp.op_weight, 0.5) END,
             dp.department_id
    LIMIT 1
) dep
CROSS JOIN LATERAL (
    SELECT dw.doctor_id FROM gen.v_doctor_weight dw
    WHERE dw.facility_id = c.facility_id AND dw.department_id = dep.department_id
      AND dw.join_date <= c.vdate
    ORDER BY -ln(1 - gen.u('cand:doc:' || c.ckey || ':' || dw.doctor_id)) / dw.weight, dw.doctor_id
    LIMIT 1
) doc;

/* ---------------------------------------------------------------------------
   E. IC-01: drop non-IP encounters strictly inside one of the patient's stays.
   Appointment-linked OP visits are protected by the assignment rule above;
   the assertion below proves none had to be dropped.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_ic01_drop;
CREATE TEMP TABLE tmp_ic01_drop AS
SELECT v.src_key, v.visit_type, v.appointment_id
FROM tmp_vis v
WHERE v.visit_type <> 'IP'
  AND EXISTS (SELECT 1 FROM tmp_vis s
              WHERE s.visit_type = 'IP' AND s.patient_id = v.patient_id
                AND v.visit_date > s.admission_date AND v.visit_date < s.discharge_date);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM tmp_ic01_drop WHERE appointment_id IS NOT NULL) THEN
    RAISE EXCEPTION 'IC-01 assertion failed: an appointment-linked OP visit falls inside a stay';
  END IF;
END $$;

DELETE FROM tmp_vis v USING tmp_ic01_drop x WHERE v.src_key = x.src_key;

/* ---------------------------------------------------------------------------
   F. Load raw.visits with date-ordered IDs
   ------------------------------------------------------------------------ */
INSERT INTO raw.visits
SELECT 'VIS' || lpad(row_number() OVER (
           ORDER BY v.visit_date,
                    CASE v.visit_type WHEN 'ER' THEN 1 WHEN 'OP' THEN 2 WHEN 'Day-care' THEN 3 ELSE 4 END,
                    v.patient_id, v.src_key)::text, 6, '0'),
       v.patient_id, v.doctor_id, v.department_id, v.facility_id, v.appointment_id,
       v.visit_type, v.visit_date, v.admission_date, v.discharge_date, v.discharge_status
FROM tmp_vis v;

/* ---------------------------------------------------------------------------
   G. Finalise registration = first contact (earliest booking date or visit date)
      and remove candidates that never had any contact
   ------------------------------------------------------------------------ */
WITH events AS (
    SELECT patient_id, booking_datetime::date AS d, facility_id, 0 AS pri, appointment_id AS ekey
    FROM raw.appointments
    UNION ALL
    SELECT patient_id, visit_date, facility_id, 1, visit_id
    FROM raw.visits
),
first_ev AS (
    SELECT DISTINCT ON (patient_id) patient_id, d, facility_id
    FROM events
    ORDER BY patient_id, d, pri, ekey
)
UPDATE raw.patients p
SET registration_date = f.d,
    registration_facility_id = f.facility_id
FROM first_ev f
WHERE p.patient_id = f.patient_id;

DELETE FROM raw.patients p
WHERE NOT EXISTS (SELECT 1 FROM raw.appointments a WHERE a.patient_id = p.patient_id)
  AND NOT EXISTS (SELECT 1 FROM raw.visits v       WHERE v.patient_id = p.patient_id);

/* ---------------------------------------------------------------------------
   H. DQ-07 duplicate-like patient records (raw only)
   For selected patients with >= 4 events on >= 2 distinct dates, events on or
   after a split date are moved to a NEW patient_id carrying the same identity.
   Each raw record stays internally valid; 10_data_cleaning.sql merges them
   back (survivor = earliest registration) and the combined history is the
   original, rule-compliant history.
   ------------------------------------------------------------------------ */
DROP TABLE IF EXISTS tmp_dup;
CREATE TEMP TABLE tmp_dup AS
WITH ev AS (
    SELECT patient_id, scheduled_datetime::date AS d FROM raw.appointments
    UNION ALL
    SELECT patient_id, visit_date FROM raw.visits WHERE appointment_id IS NULL
),
per AS (
    SELECT patient_id, count(*) AS n_ev,
           percentile_disc(0.5) WITHIN GROUP (ORDER BY d) AS split_date,
           min(d) AS first_d
    FROM ev GROUP BY patient_id
),
chosen AS (
    SELECT p.*
    FROM per p
    WHERE p.n_ev >= 4
      AND p.split_date > p.first_d
      AND gen.u('dq07:' || p.patient_id) < (SELECT dq_patient_dup_share_of_eligible FROM gen.v_params)
)
SELECT c.patient_id AS old_id,
       'PAT' || lpad(((SELECT max(substr(patient_id, 4)::int) FROM raw.patients)
                      + row_number() OVER (ORDER BY c.patient_id))::text, 5, '0') AS new_id,
       c.split_date
FROM chosen c;

INSERT INTO raw.patients
SELECT d.new_id, p.patient_name, p.gender, p.date_of_birth, p.city, p.state,
       p.registration_date, p.registration_facility_id      -- recomputed below
FROM tmp_dup d JOIN raw.patients p ON p.patient_id = d.old_id;

UPDATE raw.appointments a SET patient_id = d.new_id
FROM tmp_dup d
WHERE a.patient_id = d.old_id AND a.scheduled_datetime::date >= d.split_date;

UPDATE raw.visits v SET patient_id = d.new_id
FROM tmp_dup d
WHERE v.patient_id = d.old_id AND v.visit_date >= d.split_date;

-- recompute registration for both halves
WITH ids AS (SELECT old_id AS pid FROM tmp_dup UNION SELECT new_id FROM tmp_dup),
events AS (
    SELECT a.patient_id, a.booking_datetime::date AS d, a.facility_id, 0 AS pri, a.appointment_id AS ekey
    FROM raw.appointments a JOIN ids ON ids.pid = a.patient_id
    UNION ALL
    SELECT v.patient_id, v.visit_date, v.facility_id, 1, v.visit_id
    FROM raw.visits v JOIN ids ON ids.pid = v.patient_id
),
first_ev AS (
    SELECT DISTINCT ON (patient_id) patient_id, d, facility_id
    FROM events ORDER BY patient_id, d, pri, ekey
)
UPDATE raw.patients p
SET registration_date = f.d, registration_facility_id = f.facility_id
FROM first_ev f WHERE p.patient_id = f.patient_id;

/* ---------------------------------------------------------------------------
   I. Patient attribute DQ (raw only): DQ-01 city casing, DQ-02 whitespace,
      DQ-08 gender label variants
   ------------------------------------------------------------------------ */
UPDATE raw.patients
SET city = CASE WHEN gen.u('dq01v:' || patient_id) < 0.5 THEN lower(city) ELSE upper(city) END
WHERE gen.u('dq01:' || patient_id) < 0.04;

UPDATE raw.patients
SET patient_name = CASE WHEN gen.u('dq02v:' || patient_id) < 0.5
                        THEN ' ' || patient_name ELSE patient_name || '  ' END
WHERE gen.u('dq02n:' || patient_id) < 0.03;

UPDATE raw.patients
SET city = city || ' '
WHERE gen.u('dq02c:' || patient_id) < 0.02;

UPDATE raw.patients
SET gender = CASE gender
        WHEN 'Male'   THEN gen.pick('dq08v:' || patient_id, ARRAY['M','male','MALE'])
        WHEN 'Female' THEN gen.pick('dq08v:' || patient_id, ARRAY['F','female','FEMALE'])
        ELSE 'other' END
WHERE gen.u('dq08:' || patient_id) < 0.03;

/* ---------------------------------------------------------------------------
   J. Generation diagnostics (transparency; not findings)
   ------------------------------------------------------------------------ */
SELECT 'ip_slots_on_bed_timelines'          AS metric, count(*)::numeric AS value FROM tmp_stay
UNION ALL SELECT 'ip_stays_unassigned_dropped', count(*) FROM tmp_stay WHERE patient_id IS NULL
UNION ALL SELECT 'ip_capacity_adjustments (by construction)', 0
UNION ALL SELECT 'ic01_dropped_' || lower(visit_type), count(*) FROM tmp_ic01_drop GROUP BY visit_type
UNION ALL SELECT 'patients_removed_no_contact',
          (SELECT candidate_patients FROM gen.v_params)
          - (SELECT count(*) FROM raw.patients WHERE patient_id NOT IN (SELECT new_id FROM tmp_dup))
UNION ALL SELECT 'duplicate_like_records_created', count(*) FROM tmp_dup
UNION ALL SELECT 'visits_' || lower(visit_type), count(*) FROM raw.visits GROUP BY visit_type
UNION ALL SELECT 'visits_total', count(*) FROM raw.visits
UNION ALL SELECT 'patients_total_raw', count(*) FROM raw.patients;

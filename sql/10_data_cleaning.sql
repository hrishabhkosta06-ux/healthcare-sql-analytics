/* =============================================================================
   10_data_cleaning.sql
   raw.*  ->  processed.*   (all transformations in SQL; raw is never modified)

   DQ-01 city casing          -> initcap(lower(trim(city)))
   DQ-02 whitespace           -> btrim + collapse internal spaces (names)
   DQ-03 payer label variants -> mapped to 4 canonical payer types
   DQ-04 channel variants     -> mapped to 4 canonical channels
   DQ-05 NULL cancel reason   -> 'Not recorded' (Cancelled rows only)
   DQ-06 NULL channel         -> 'Unknown'
   DQ-07 duplicate-like       -> identify survivor (earliest registration, then
                                 lowest ID), remap ALL child rows, keep one
                                 patient row; nothing is deleted from children
   DQ-08 gender variants      -> 'Male' / 'Female' / 'Other'

   processed tables carry full CHECK constraints, so any cleaning defect makes
   this script fail loudly instead of loading bad data.
   The merge map is exposed as a VIEW (processed.v_patient_merge_map) for
   auditability - no permanent helper table is created.
   ========================================================================== */

TRUNCATE processed.payments, processed.billing, processed.visit_procedures,
         processed.visits, processed.appointments, processed.patients,
         processed.procedures, processed.doctors, processed.departments,
         processed.facilities;

-- Reference tables are generated clean; copied as-is
INSERT INTO processed.facilities  SELECT * FROM raw.facilities;
INSERT INTO processed.departments SELECT * FROM raw.departments;
INSERT INTO processed.doctors     SELECT * FROM raw.doctors;
INSERT INTO processed.procedures  SELECT * FROM raw.procedures;

/* ---------------------------------------------------------------------------
   Patient identity + survivor map (DQ-07)
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW processed.v_patient_merge_map AS
WITH norm AS (
    SELECT patient_id, registration_date, date_of_birth,
           lower(regexp_replace(btrim(patient_name), '\s+', ' ', 'g')) AS n_name,
           initcap(lower(btrim(city)))                                  AS n_city,
           CASE lower(btrim(gender)) WHEN 'm' THEN 'Male' WHEN 'male' THEN 'Male'
                                     WHEN 'f' THEN 'Female' WHEN 'female' THEN 'Female'
                                     WHEN 'other' THEN 'Other' END      AS n_gender
    FROM raw.patients
)
SELECT patient_id AS raw_patient_id,
       first_value(patient_id) OVER w AS survivor_id,
       count(*) OVER (PARTITION BY n_name, date_of_birth, n_gender, n_city) AS records_in_group
FROM norm
WINDOW w AS (PARTITION BY n_name, date_of_birth, n_gender, n_city
             ORDER BY registration_date, patient_id
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);

INSERT INTO processed.patients
SELECT r.patient_id,
       regexp_replace(btrim(r.patient_name), '\s+', ' ', 'g'),
       CASE lower(btrim(r.gender)) WHEN 'm' THEN 'Male' WHEN 'male' THEN 'Male'
                                   WHEN 'f' THEN 'Female' WHEN 'female' THEN 'Female'
                                   ELSE 'Other' END,
       r.date_of_birth,
       initcap(lower(btrim(r.city))),
       r.state,
       r.registration_date,            -- survivor is the earliest-registered record
       r.registration_facility_id
FROM raw.patients r
JOIN processed.v_patient_merge_map m ON m.raw_patient_id = r.patient_id
WHERE m.survivor_id = r.patient_id;

/* ---------------------------------------------------------------------------
   Appointments: remap patient, standardise channel and reason
   ------------------------------------------------------------------------ */
INSERT INTO processed.appointments
SELECT a.appointment_id,
       m.survivor_id,
       a.doctor_id,
       a.facility_id,
       a.booking_datetime,
       a.scheduled_datetime,
       a.appointment_status,
       CASE WHEN a.appointment_status = 'Cancelled'
            THEN coalesce(a.cancellation_reason, 'Not recorded') END,
       CASE regexp_replace(lower(btrim(a.booking_channel)), '\s+', ' ', 'g')
            WHEN 'phone'      THEN 'Phone'
            WHEN 'website'    THEN 'Website'
            WHEN 'web'        THEN 'Website'
            WHEN 'mobile app' THEN 'Mobile App'
            WHEN 'app'        THEN 'Mobile App'
            WHEN 'front desk' THEN 'Front Desk'
            WHEN 'frontdesk'  THEN 'Front Desk'
            ELSE 'Unknown' END                       -- includes NULL (DQ-06)
FROM raw.appointments a
JOIN processed.v_patient_merge_map m ON m.raw_patient_id = a.patient_id;

/* ---------------------------------------------------------------------------
   Visits: remap patient only
   ------------------------------------------------------------------------ */
INSERT INTO processed.visits
SELECT v.visit_id, m.survivor_id, v.doctor_id, v.department_id, v.facility_id,
       v.appointment_id, v.visit_type, v.visit_date, v.admission_date,
       v.discharge_date, v.discharge_status
FROM raw.visits v
JOIN processed.v_patient_merge_map m ON m.raw_patient_id = v.patient_id;

INSERT INTO processed.visit_procedures SELECT * FROM raw.visit_procedures;

/* ---------------------------------------------------------------------------
   Billing: standardise payer label (DQ-03)
   ------------------------------------------------------------------------ */
INSERT INTO processed.billing
SELECT b.bill_id, b.visit_id, b.bill_date,
       b.consultation_charges, b.procedure_charges, b.room_charges,
       b.pharmacy_charges, b.diagnostics_charges,
       b.gross_amount, b.discount_amount, b.net_amount,
       CASE regexp_replace(lower(btrim(b.payer_type)), '[\s-]+', ' ', 'g')
            WHEN 'self pay'          THEN 'Self-pay'
            WHEN 'insurance tpa'     THEN 'Insurance-TPA'
            WHEN 'corporate'         THEN 'Corporate'
            WHEN 'govt scheme'       THEN 'Govt scheme'
            WHEN 'government scheme' THEN 'Govt scheme'
       END                          -- unmapped label -> NULL -> NOT NULL violation (fail loudly)
FROM raw.billing b;

INSERT INTO processed.payments SELECT * FROM raw.payments;

ANALYZE processed.facilities, processed.departments, processed.doctors, processed.patients,
        processed.appointments, processed.visits, processed.procedures,
        processed.visit_procedures, processed.billing, processed.payments;

/* ---------------------------------------------------------------------------
   Cleaning log (counts of raw rows changed per DQ scenario)
   ------------------------------------------------------------------------ */
SELECT 'DQ-01/02 patient name/city standardised' AS action,
       count(*) AS rows_changed
FROM raw.patients r JOIN processed.patients p USING (patient_id)
WHERE r.patient_name <> p.patient_name OR r.city <> p.city
UNION ALL
SELECT 'DQ-03 payer label mapped', count(*)
FROM raw.billing r JOIN processed.billing p USING (bill_id) WHERE r.payer_type <> p.payer_type
UNION ALL
SELECT 'DQ-04/06 channel mapped or set Unknown', count(*)
FROM raw.appointments r JOIN processed.appointments p USING (appointment_id)
WHERE r.booking_channel IS DISTINCT FROM p.booking_channel
UNION ALL
SELECT 'DQ-05 cancellation reason set Not recorded', count(*)
FROM processed.appointments WHERE cancellation_reason = 'Not recorded'
UNION ALL
SELECT 'DQ-07 duplicate-like records merged (non-survivors)', count(*)
FROM processed.v_patient_merge_map WHERE raw_patient_id <> survivor_id
UNION ALL
SELECT 'DQ-07 child appointments remapped', count(*)
FROM raw.appointments r JOIN processed.appointments p USING (appointment_id)
WHERE r.patient_id <> p.patient_id
UNION ALL
SELECT 'DQ-07 child visits remapped', count(*)
FROM raw.visits r JOIN processed.visits p USING (visit_id)
WHERE r.patient_id <> p.patient_id
UNION ALL
SELECT 'DQ-08 gender label standardised', count(*)
FROM raw.patients r JOIN processed.patients p USING (patient_id) WHERE r.gender <> p.gender
UNION ALL
SELECT 'Row-count check: child rows lost in cleaning (must be 0)',
       ((SELECT count(*) FROM raw.appointments)     - (SELECT count(*) FROM processed.appointments))
     + ((SELECT count(*) FROM raw.visits)           - (SELECT count(*) FROM processed.visits))
     + ((SELECT count(*) FROM raw.visit_procedures) - (SELECT count(*) FROM processed.visit_procedures))
     + ((SELECT count(*) FROM raw.billing)          - (SELECT count(*) FROM processed.billing))
     + ((SELECT count(*) FROM raw.payments)         - (SELECT count(*) FROM processed.payments));

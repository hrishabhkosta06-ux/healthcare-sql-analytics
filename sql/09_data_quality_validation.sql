/* =============================================================================
   09_data_quality_validation.sql
   One interpretable result set: check_id | category | check_name |
                                 violations | status

   Schema-agnostic: run it twice.
       SET search_path = raw;        \i 09_data_quality_validation.sql
       SET search_path = processed;  \i 09_data_quality_validation.sql
   Status meaning
       PASS      - zero violations
       FAIL      - structural/integrity rule broken (must never happen)
       DQ_FOUND  - a documented, deliberate raw data-quality issue was
                   detected (expected in raw; must be 0 in processed)
   Text normalisation inside checks lets integrity rules be tested on raw data
   even where labels are inconsistent.
   ========================================================================== */

WITH
p AS (   -- normalised patient attributes (identity for duplicate-like checks)
    SELECT patient_id, registration_date, date_of_birth,
           lower(regexp_replace(btrim(patient_name), '\s+', ' ', 'g'))     AS n_name,
           initcap(lower(btrim(city)))                                      AS n_city,
           CASE lower(btrim(gender)) WHEN 'm' THEN 'Male' WHEN 'male' THEN 'Male'
                                     WHEN 'f' THEN 'Female' WHEN 'female' THEN 'Female'
                                     WHEN 'other' THEN 'Other' END          AS n_gender,
           patient_name, city, gender
    FROM patients
),
ip AS (  -- IP stays with half-open occupancy end
    SELECT visit_id, patient_id, facility_id, admission_date, discharge_date,
           admission_date + greatest(discharge_date - admission_date, 1) AS end_excl
    FROM visits WHERE visit_type = 'IP'
),
census AS (
    SELECT ip.facility_id, d::date AS day, count(*) AS census
    FROM ip CROSS JOIN LATERAL generate_series(ip.admission_date, ip.end_excl - 1, interval '1 day') d
    GROUP BY ip.facility_id, d::date
),
first_contact AS (
    SELECT patient_id, min(d) AS first_d FROM (
        SELECT patient_id, booking_datetime::date AS d FROM appointments
        UNION ALL SELECT patient_id, visit_date FROM visits) e
    GROUP BY patient_id
),
paid AS (
    SELECT bill_id, sum(amount_paid) FILTER (WHERE payment_status = 'Success') AS success_paid
    FROM payments GROUP BY bill_id
),
checks(check_id, category, check_name, violations, is_dq) AS (
    -- ---------------- STRUCTURAL ----------------
    SELECT 'S01','Structural','Primary keys unique and non-null (all 10 tables)',
      (SELECT count(*) - count(DISTINCT facility_id) + count(*) FILTER (WHERE facility_id IS NULL) FROM facilities)
    + (SELECT count(*) - count(DISTINCT department_id) FROM departments)
    + (SELECT count(*) - count(DISTINCT doctor_id) FROM doctors)
    + (SELECT count(*) - count(DISTINCT patient_id) FROM patients)
    + (SELECT count(*) - count(DISTINCT appointment_id) FROM appointments)
    + (SELECT count(*) - count(DISTINCT visit_id) FROM visits)
    + (SELECT count(*) - count(DISTINCT procedure_id) FROM procedures)
    + (SELECT count(*) - count(DISTINCT visit_procedure_id) FROM visit_procedures)
    + (SELECT count(*) - count(DISTINCT bill_id) FROM billing)
    + (SELECT count(*) - count(DISTINCT payment_id) FROM payments), false
    UNION ALL SELECT 'S02','Structural','Foreign keys resolve (orphan child rows)',
      (SELECT count(*) FROM doctors d WHERE NOT EXISTS (SELECT 1 FROM facilities f WHERE f.facility_id = d.facility_id)
                                         OR NOT EXISTS (SELECT 1 FROM departments x WHERE x.department_id = d.department_id))
    + (SELECT count(*) FROM appointments a WHERE NOT EXISTS (SELECT 1 FROM patients x WHERE x.patient_id = a.patient_id)
                                              OR NOT EXISTS (SELECT 1 FROM doctors x WHERE x.doctor_id = a.doctor_id))
    + (SELECT count(*) FROM visits v WHERE NOT EXISTS (SELECT 1 FROM patients x WHERE x.patient_id = v.patient_id)
                                        OR NOT EXISTS (SELECT 1 FROM doctors x WHERE x.doctor_id = v.doctor_id)
                                        OR (v.appointment_id IS NOT NULL AND NOT EXISTS
                                              (SELECT 1 FROM appointments x WHERE x.appointment_id = v.appointment_id)))
    + (SELECT count(*) FROM visit_procedures vp WHERE NOT EXISTS (SELECT 1 FROM visits x WHERE x.visit_id = vp.visit_id)
                                                   OR NOT EXISTS (SELECT 1 FROM procedures x WHERE x.procedure_id = vp.procedure_id))
    + (SELECT count(*) FROM billing b WHERE NOT EXISTS (SELECT 1 FROM visits x WHERE x.visit_id = b.visit_id))
    + (SELECT count(*) FROM payments y WHERE NOT EXISTS (SELECT 1 FROM billing x WHERE x.bill_id = y.bill_id)), false
    UNION ALL SELECT 'S03','Structural','Allowed values: tier, dept category, designation, appointment status, visit type, discharge status, procedure category, payment mode/status',
      (SELECT count(*) FROM facilities WHERE city_tier NOT IN ('Metro','Non-metro'))
    + (SELECT count(*) FROM departments WHERE department_category NOT IN ('Medical','Surgical','Diagnostic','Emergency'))
    + (SELECT count(*) FROM doctors WHERE designation NOT IN ('Associate Consultant','Consultant','Senior Consultant'))
    + (SELECT count(*) FROM appointments WHERE appointment_status NOT IN ('Completed','Cancelled','No-show'))
    + (SELECT count(*) FROM visits WHERE visit_type NOT IN ('OP','IP','ER','Day-care')
                                      OR (discharge_status IS NOT NULL AND discharge_status NOT IN ('Discharged','Transferred','LAMA')))
    + (SELECT count(*) FROM procedures WHERE procedure_category NOT IN
          ('Diagnostic','Minor Procedure','Interventional','Major Surgery','Therapy Session'))
    + (SELECT count(*) FROM payments WHERE payment_status NOT IN ('Success','Failed')
          OR payment_mode NOT IN ('Cash','UPI','Card','Net Banking','Insurance Settlement',
                                  'Corporate Settlement','Govt Scheme Settlement')), false
    UNION ALL SELECT 'S04','Structural','IP-only fields populated iff visit_type = IP',
      (SELECT count(*) FROM visits WHERE (visit_type = 'IP') <> (admission_date IS NOT NULL)
                                      OR (visit_type = 'IP') <> (discharge_date IS NOT NULL)
                                      OR (visit_type = 'IP') <> (discharge_status IS NOT NULL)), false
    UNION ALL SELECT 'S05','Structural','cancellation_reason present only on Cancelled appointments',
      (SELECT count(*) FROM appointments WHERE appointment_status <> 'Cancelled' AND cancellation_reason IS NOT NULL), false
    -- ---------------- DOCUMENTED DQ (expected in raw only) ----------------
    UNION ALL SELECT 'D01','DQ','DQ-01 city casing not canonical',
      (SELECT count(*) FROM p WHERE btrim(city) <> initcap(lower(btrim(city)))), true
    UNION ALL SELECT 'D02','DQ','DQ-02 leading/trailing whitespace in patient name or city',
      (SELECT count(*) FROM p WHERE patient_name <> btrim(patient_name) OR city <> btrim(city)), true
    UNION ALL SELECT 'D03','DQ','DQ-03 payer_type label outside canonical set',
      (SELECT count(*) FROM billing WHERE payer_type NOT IN ('Self-pay','Insurance-TPA','Corporate','Govt scheme')), true
    UNION ALL SELECT 'D04','DQ','DQ-04 booking_channel label outside canonical set',
      (SELECT count(*) FROM appointments WHERE booking_channel IS NOT NULL
          AND booking_channel NOT IN ('Phone','Website','Mobile App','Front Desk','Unknown')), true
    UNION ALL SELECT 'D05','DQ','DQ-05 Cancelled appointment with NULL cancellation_reason',
      (SELECT count(*) FROM appointments WHERE appointment_status = 'Cancelled' AND cancellation_reason IS NULL), true
    UNION ALL SELECT 'D06','DQ','DQ-06 NULL booking_channel',
      (SELECT count(*) FROM appointments WHERE booking_channel IS NULL), true
    UNION ALL SELECT 'D07','DQ','DQ-07 duplicate-like patient records (same normalised name, DOB, gender, city)',
      (SELECT coalesce(sum(cnt - 1), 0) FROM (SELECT count(*) AS cnt FROM p
                    GROUP BY n_name, date_of_birth, n_gender, n_city HAVING count(*) > 1) g), true
    UNION ALL SELECT 'D08','DQ','DQ-08 gender label outside canonical set',
      (SELECT count(*) FROM patients WHERE gender NOT IN ('Male','Female','Other')), true
    -- ---------------- TEMPORAL ----------------
    UNION ALL SELECT 'T01','Temporal','DOB before registration date',
      (SELECT count(*) FROM patients WHERE date_of_birth >= registration_date), false
    UNION ALL SELECT 'T02','Temporal','Registration date = first contact (earliest booking or visit) and inside window',
      (SELECT count(*) FROM patients x LEFT JOIN first_contact f USING (patient_id)
       WHERE f.first_d IS NULL OR x.registration_date <> f.first_d
          OR x.registration_date NOT BETWEEN DATE '2023-04-01' AND DATE '2025-03-31'), false
    UNION ALL SELECT 'T03','Temporal','Booking <= scheduled; booking >= 2023-04-01; scheduled inside window',
      (SELECT count(*) FROM appointments WHERE booking_datetime > scheduled_datetime
          OR booking_datetime < TIMESTAMP '2023-04-01' OR scheduled_datetime >= TIMESTAMP '2025-04-01'), false
    UNION ALL SELECT 'T04','Temporal','Visit dates inside window; linked OP visit date = scheduled date',
      (SELECT count(*) FROM visits WHERE visit_date NOT BETWEEN DATE '2023-04-01' AND DATE '2025-03-31')
    + (SELECT count(*) FROM visits v JOIN appointments a USING (appointment_id)
       WHERE v.visit_date <> a.scheduled_datetime::date), false
    UNION ALL SELECT 'T05','Temporal','IP: admission <= discharge, visit_date = admission, no open stay at cutoff',
      (SELECT count(*) FROM visits WHERE visit_type = 'IP'
          AND (discharge_date < admission_date OR visit_date <> admission_date
               OR discharge_date > DATE '2025-03-31')), false
    UNION ALL SELECT 'T06','Temporal','No encounter or booking before date of birth',
      (SELECT count(*) FROM visits v JOIN patients x USING (patient_id) WHERE v.visit_date <= x.date_of_birth)
    + (SELECT count(*) FROM appointments a JOIN patients x USING (patient_id)
       WHERE a.booking_datetime::date <= x.date_of_birth), false
    UNION ALL SELECT 'T07','Temporal','Doctor had joined by booking date / visit date',
      (SELECT count(*) FROM appointments a JOIN doctors d USING (doctor_id) WHERE d.join_date > a.booking_datetime::date)
    + (SELECT count(*) FROM visits v JOIN doctors d USING (doctor_id) WHERE d.join_date > v.visit_date), false
    UNION ALL SELECT 'T08','Temporal','Procedure date within stay (IP) or equal to visit date (others)',
      (SELECT count(*) FROM visit_procedures vp JOIN visits v USING (visit_id)
       WHERE (v.visit_type = 'IP' AND vp.procedure_date NOT BETWEEN v.admission_date AND v.discharge_date)
          OR (v.visit_type <> 'IP' AND vp.procedure_date <> v.visit_date)), false
    UNION ALL SELECT 'T09','Temporal','bill_date = discharge_date (IP) else visit_date',
      (SELECT count(*) FROM billing b JOIN visits v USING (visit_id)
       WHERE b.bill_date <> CASE WHEN v.visit_type = 'IP' THEN v.discharge_date ELSE v.visit_date END), false
    UNION ALL SELECT 'T10','Temporal','payment_date between bill_date and 2025-03-31',
      (SELECT count(*) FROM payments y JOIN billing b USING (bill_id)
       WHERE y.payment_date < b.bill_date OR y.payment_date > DATE '2025-03-31'), false
    -- ---------------- APPOINTMENT -> VISIT ----------------
    UNION ALL SELECT 'A01','Appointment','Completed appointment without exactly one visit',
      (SELECT count(*) FROM appointments a WHERE a.appointment_status = 'Completed'
          AND (SELECT count(*) FROM visits v WHERE v.appointment_id = a.appointment_id) <> 1), false
    UNION ALL SELECT 'A02','Appointment','Cancelled / No-show appointment linked to a visit',
      (SELECT count(*) FROM appointments a JOIN visits v USING (appointment_id)
       WHERE a.appointment_status <> 'Completed'), false
    UNION ALL SELECT 'A03','Appointment','Linked visit differs from appointment (patient/doctor/facility) or is not OP',
      (SELECT count(*) FROM visits v JOIN appointments a USING (appointment_id)
       WHERE v.patient_id <> a.patient_id OR v.doctor_id <> a.doctor_id
          OR v.facility_id <> a.facility_id OR v.visit_type <> 'OP'), false
    -- ---------------- PATIENT ----------------
    UNION ALL SELECT 'P01','Patient','Department eligibility (Paediatrics <18; O&G female 18-50; minors only in Paeds/ER/Radiology)',
      (SELECT count(*) FROM visits v JOIN p USING (patient_id)
       WHERE NOT CASE
           WHEN v.department_id = 'DEP12' THEN date_part('year', age(v.visit_date, p.date_of_birth)) < 18
           WHEN v.department_id = 'DEP11' THEN p.n_gender = 'Female'
                AND date_part('year', age(v.visit_date, p.date_of_birth)) BETWEEN 18 AND 50
           WHEN v.department_id IN ('DEP01','DEP14') THEN true
           ELSE date_part('year', age(v.visit_date, p.date_of_birth)) >= 18 END), false
    -- ---------------- INPATIENT ----------------
    UNION ALL SELECT 'I01','Inpatient','Overlapping IP stays for the same patient',
      (SELECT count(*) FROM ip a JOIN ip b ON a.patient_id = b.patient_id AND a.visit_id < b.visit_id
       WHERE a.admission_date < b.end_excl AND b.admission_date < a.end_excl), false
    UNION ALL SELECT 'I02','Inpatient','IC-01: OP/ER/Day-care visit strictly inside the patient''s stay',
      (SELECT count(*) FROM visits v JOIN ip ON ip.patient_id = v.patient_id
       WHERE v.visit_type <> 'IP' AND v.visit_date > ip.admission_date AND v.visit_date < ip.discharge_date), false
    UNION ALL SELECT 'I03','Inpatient','Patient-days >= 1 for every stay',
      (SELECT count(*) FROM ip WHERE end_excl - admission_date < 1), false
    UNION ALL SELECT 'I04','Inpatient','Facility-days where IP census exceeds operating beds',
      (SELECT count(*) FROM census c JOIN facilities f USING (facility_id)
       WHERE c.census > f.operating_bed_count), false
    -- ---------------- FINANCIAL ----------------
    UNION ALL SELECT 'F01','Financial','gross_amount = sum of five components',
      (SELECT count(*) FROM billing WHERE gross_amount <> consultation_charges + procedure_charges
          + room_charges + pharmacy_charges + diagnostics_charges), false
    UNION ALL SELECT 'F02','Financial','net = gross - discount; 0 <= discount <= gross; net > 0',
      (SELECT count(*) FROM billing WHERE net_amount <> gross_amount - discount_amount
          OR discount_amount < 0 OR discount_amount > gross_amount OR net_amount <= 0), false
    UNION ALL SELECT 'F03','Financial','procedure_charges = SUM(visit_procedures.charged_amount)',
      (SELECT count(*) FROM billing b
       WHERE b.procedure_charges <> coalesce((SELECT sum(charged_amount) FROM visit_procedures vp
                                              WHERE vp.visit_id = b.visit_id), 0)), false
    UNION ALL SELECT 'F04','Financial','Successful payments exceed net amount (negative outstanding)',
      (SELECT count(*) FROM billing b JOIN paid USING (bill_id) WHERE paid.success_paid > b.net_amount), false
    UNION ALL SELECT 'F05','Financial','Failed attempt without a successful payment of the same bill on the same date',
      (SELECT count(*) FROM payments f WHERE f.payment_status = 'Failed'
          AND NOT EXISTS (SELECT 1 FROM payments s WHERE s.bill_id = f.bill_id
                          AND s.payment_status = 'Success' AND s.payment_date = f.payment_date)), false
    UNION ALL SELECT 'F06','Financial','Non-positive amounts (charges, prices, payments)',
      (SELECT count(*) FROM visit_procedures WHERE charged_amount <= 0)
    + (SELECT count(*) FROM procedures WHERE standard_price <= 0)
    + (SELECT count(*) FROM payments WHERE amount_paid <= 0), false
    -- ---------------- RELATIONSHIP ----------------
    UNION ALL SELECT 'R01','Relationship','Exactly one bill per visit',
      (SELECT count(*) FROM visits v WHERE (SELECT count(*) FROM billing b WHERE b.visit_id = v.visit_id) <> 1), false
    UNION ALL SELECT 'R02','Relationship','Visit department/facility = treating doctor''s department/facility',
      (SELECT count(*) FROM visits v JOIN doctors d USING (doctor_id)
       WHERE v.department_id <> d.department_id OR v.facility_id <> d.facility_id), false
    UNION ALL SELECT 'R03','Relationship','Appointment facility = doctor''s facility',
      (SELECT count(*) FROM appointments a JOIN doctors d USING (doctor_id) WHERE a.facility_id <> d.facility_id), false
    UNION ALL SELECT 'R04','Relationship','Procedure department = visit department',
      (SELECT count(*) FROM visit_procedures vp JOIN visits v USING (visit_id) JOIN procedures pr USING (procedure_id)
       WHERE pr.department_id <> v.department_id), false
    UNION ALL SELECT 'R05','Relationship','Day-care visit without a procedure; ER visit outside Emergency Medicine',
      (SELECT count(*) FROM visits v WHERE v.visit_type = 'Day-care'
          AND NOT EXISTS (SELECT 1 FROM visit_procedures vp WHERE vp.visit_id = v.visit_id))
    + (SELECT count(*) FROM visits WHERE visit_type = 'ER' AND department_id <> 'DEP01'), false
)
SELECT check_id, category, check_name, violations,
       CASE WHEN violations = 0 THEN 'PASS'
            WHEN is_dq          THEN 'DQ_FOUND'
            ELSE                     'FAIL' END AS status
FROM checks
ORDER BY CASE category WHEN 'Structural' THEN 1 WHEN 'DQ' THEN 2 WHEN 'Temporal' THEN 3
                       WHEN 'Appointment' THEN 4 WHEN 'Patient' THEN 5 WHEN 'Inpatient' THEN 6
                       WHEN 'Financial' THEN 7 ELSE 8 END, check_id;

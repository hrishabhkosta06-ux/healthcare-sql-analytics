/* =============================================================================
   11_reconciliation.sql   (runs on processed.*)
   Every row compares two independently computed totals:
       rec_id | reconciliation | value_a | value_b | difference | status
   PASS = difference within tolerance (0 for counts/money; 0.01 pp for %).
   Revenue = net_amount unless stated (documentation/kpi_definitions.md).
   Indian FY: FY start year = year of (date - 3 months).
   ========================================================================== */
SET search_path = processed;

WITH
fy AS (SELECT * FROM (VALUES ('FY2023-24', DATE '2023-04-01', DATE '2024-03-31'),
                             ('FY2024-25', DATE '2024-04-01', DATE '2025-03-31')) t(fy, s, e)),
rev AS (
    SELECT b.*, v.department_id, v.doctor_id, v.facility_id, v.visit_type
    FROM billing b JOIN visits v USING (visit_id)
),
-- patient classification per FY (documentation/kpi_definitions.md)
first_visit AS (SELECT patient_id, min(visit_date) AS first_d FROM visits GROUP BY patient_id),
fy_patients AS (
    SELECT fy.fy, v.patient_id, fv.first_d, fy.s
    FROM fy JOIN visits v ON v.visit_date BETWEEN fy.s AND fy.e
    JOIN first_visit fv USING (patient_id)
    GROUP BY fy.fy, v.patient_id, fv.first_d, fy.s
),
paid AS (SELECT bill_id, sum(amount_paid) FILTER (WHERE payment_status = 'Success') AS ok_paid
         FROM payments GROUP BY bill_id),
ip AS (SELECT visit_id, facility_id, admission_date,
              greatest(discharge_date - admission_date, 1) AS patient_days,
              admission_date + greatest(discharge_date - admission_date, 1) AS end_excl
       FROM visits WHERE visit_type = 'IP'),
ip_days AS (SELECT ip.facility_id, d::date AS day
            FROM ip CROSS JOIN LATERAL generate_series(ip.admission_date, ip.end_excl - 1, interval '1 day') d),
recs(rec_id, reconciliation, value_a, value_b, tol) AS (
    -- Visits
    SELECT 'RC01', 'Total visits = OP + IP + ER + Day-care',
           (SELECT count(*) FROM visits)::numeric,
           (SELECT count(*) FILTER (WHERE visit_type = 'OP') + count(*) FILTER (WHERE visit_type = 'IP')
                 + count(*) FILTER (WHERE visit_type = 'ER') + count(*) FILTER (WHERE visit_type = 'Day-care')
            FROM visits)::numeric, 0
    UNION ALL
    SELECT 'RC02', 'Appointments = Completed + Cancelled + No-show',
           (SELECT count(*) FROM appointments),
           (SELECT count(*) FILTER (WHERE appointment_status = 'Completed')
                 + count(*) FILTER (WHERE appointment_status = 'Cancelled')
                 + count(*) FILTER (WHERE appointment_status = 'No-show') FROM appointments), 0
    UNION ALL
    SELECT 'RC03', 'Completed appointments = appointment-linked OP visits',
           (SELECT count(*) FROM appointments WHERE appointment_status = 'Completed'),
           (SELECT count(*) FROM visits WHERE appointment_id IS NOT NULL), 0
    -- Patients
    UNION ALL
    SELECT 'RC04', 'FY2023-24: new + returning = total patients',
           (SELECT count(*) FROM fy_patients WHERE fy = 'FY2023-24'),
           (SELECT count(*) FILTER (WHERE first_d >= s) + count(*) FILTER (WHERE first_d < s)
            FROM fy_patients WHERE fy = 'FY2023-24'), 0
    UNION ALL
    SELECT 'RC05', 'FY2024-25: new + returning = total patients',
           (SELECT count(*) FROM fy_patients WHERE fy = 'FY2024-25'),
           (SELECT count(*) FILTER (WHERE first_d >= s) + count(*) FILTER (WHERE first_d < s)
            FROM fy_patients WHERE fy = 'FY2024-25'), 0
    UNION ALL
    SELECT 'RC06', 'Distinct patients with visits = patients table rows with visits',
           (SELECT count(DISTINCT patient_id) FROM visits),
           (SELECT count(*) FROM patients p WHERE EXISTS (SELECT 1 FROM visits v WHERE v.patient_id = p.patient_id)), 0
    -- Billing
    UNION ALL
    SELECT 'RC07', 'SUM(gross) - SUM(discount) = SUM(net)',
           (SELECT sum(gross_amount) - sum(discount_amount) FROM billing),
           (SELECT sum(net_amount) FROM billing), 0
    UNION ALL
    SELECT 'RC08', 'SUM(gross) = SUM of five component totals',
           (SELECT sum(gross_amount) FROM billing),
           (SELECT sum(consultation_charges) + sum(procedure_charges) + sum(room_charges)
                 + sum(pharmacy_charges) + sum(diagnostics_charges) FROM billing), 0
    UNION ALL
    SELECT 'RC09', 'Bills = visits',
           (SELECT count(*) FROM billing), (SELECT count(*) FROM visits), 0
    -- Procedures
    UNION ALL
    SELECT 'RC10', 'Procedure lines total = SUM over procedures of procedure totals',
           (SELECT sum(charged_amount) FROM visit_procedures),
           (SELECT sum(t) FROM (SELECT procedure_id, sum(charged_amount) AS t
                                FROM visit_procedures GROUP BY procedure_id) x), 0
    UNION ALL
    SELECT 'RC11', 'Procedure lines total = SUM(billing.procedure_charges)',
           (SELECT sum(charged_amount) FROM visit_procedures),
           (SELECT sum(procedure_charges) FROM billing), 0
    UNION ALL
    SELECT 'RC12', 'Procedure volume (SUM quantity) = SUM over departments',
           (SELECT sum(quantity) FROM visit_procedures),
           (SELECT sum(q) FROM (SELECT pr.department_id, sum(vp.quantity) AS q
                                FROM visit_procedures vp JOIN procedures pr USING (procedure_id)
                                GROUP BY pr.department_id) x), 0
    -- Payments
    UNION ALL
    SELECT 'RC13', 'Bills where successful collections exceed net (must be 0)',
           (SELECT count(*) FROM billing b JOIN paid USING (bill_id) WHERE paid.ok_paid > b.net_amount), 0, 0
    UNION ALL
    SELECT 'RC14', 'Net billed - successful collections = SUM of per-bill outstanding',
           (SELECT sum(net_amount) FROM billing)
             - (SELECT sum(amount_paid) FROM payments WHERE payment_status = 'Success'),
           (SELECT sum(b.net_amount - coalesce(paid.ok_paid, 0)) FROM billing b LEFT JOIN paid USING (bill_id)), 0
    UNION ALL
    SELECT 'RC15', 'Successful collections = SUM over payer types',
           (SELECT sum(amount_paid) FROM payments WHERE payment_status = 'Success'),
           (SELECT sum(t) FROM (SELECT b.payer_type, sum(y.amount_paid) AS t
                                FROM payments y JOIN billing b USING (bill_id)
                                WHERE y.payment_status = 'Success' GROUP BY b.payer_type) x), 0
    -- Revenue groupings
    UNION ALL
    SELECT 'RC16', 'Total net revenue = SUM of department revenue',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(t) FROM (SELECT department_id, sum(net_amount) t FROM rev GROUP BY 1) x), 0
    UNION ALL
    SELECT 'RC17', 'Departments where SUM(doctor revenue) <> department revenue (must be 0)',
           (SELECT count(*) FROM (
               SELECT department_id, sum(net_amount) AS dept_rev,
                      (SELECT sum(t) FROM (SELECT r2.doctor_id, sum(r2.net_amount) t FROM rev r2
                                           WHERE r2.department_id = r.department_id GROUP BY 1) y) AS doc_rev
               FROM rev r GROUP BY department_id) z WHERE dept_rev <> doc_rev), 0, 0
    UNION ALL
    SELECT 'RC18', 'Total net revenue = SUM of payer revenue',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(t) FROM (SELECT payer_type, sum(net_amount) t FROM billing GROUP BY 1) x), 0
    UNION ALL
    SELECT 'RC19', 'Total net revenue = SUM of facility revenue',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(t) FROM (SELECT facility_id, sum(net_amount) t FROM rev GROUP BY 1) x), 0
    UNION ALL
    SELECT 'RC20', 'Total net revenue = SUM of monthly revenue (bill_date)',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(t) FROM (SELECT date_trunc('month', bill_date) m, sum(net_amount) t FROM billing GROUP BY 1) x), 0
    UNION ALL
    SELECT 'RC21', 'Total net revenue = FY2023-24 + FY2024-25',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(net_amount) FILTER (WHERE bill_date <= DATE '2024-03-31')
                 + sum(net_amount) FILTER (WHERE bill_date >= DATE '2024-04-01') FROM billing), 0
    -- Occupancy / patient-days
    UNION ALL
    SELECT 'RC22', 'Facility-days with census > operating beds (must be 0)',
           (SELECT count(*) FROM (SELECT facility_id, day, count(*) c FROM ip_days GROUP BY 1, 2) c
            JOIN facilities f USING (facility_id) WHERE c.c > f.operating_bed_count), 0, 0
    UNION ALL
    SELECT 'RC23', 'Patient-days: SUM of stay LOS = SUM of daily census',
           (SELECT sum(patient_days) FROM ip),
           (SELECT count(*) FROM ip_days), 0
    UNION ALL
    SELECT 'RC24', 'Patient-days: SUM of stay LOS = SUM of month-allocated patient-days',
           (SELECT sum(patient_days) FROM ip),
           (SELECT sum(pd) FROM (SELECT date_trunc('month', day) m, count(*) pd FROM ip_days GROUP BY 1) x), 0
    -- Contribution percentages
    UNION ALL
    SELECT 'RC25', 'Department revenue contribution sums to 100%',
           100, (SELECT round(sum(pct), 6) FROM (SELECT 100.0 * sum(net_amount) / sum(sum(net_amount)) OVER () pct
                                                  FROM rev GROUP BY department_id) x), 0.01
    UNION ALL
    SELECT 'RC26', 'Payer mix sums to 100%',
           100, (SELECT round(sum(pct), 6) FROM (SELECT 100.0 * sum(net_amount) / sum(sum(net_amount)) OVER () pct
                                                  FROM billing GROUP BY payer_type) x), 0.01
    UNION ALL
    SELECT 'RC27', 'Procedure revenue contribution sums to 100%',
           100, (SELECT round(sum(pct), 6) FROM (SELECT 100.0 * sum(charged_amount) / sum(sum(charged_amount)) OVER () pct
                                                  FROM visit_procedures GROUP BY procedure_id) x), 0.01
)
SELECT rec_id, reconciliation, value_a, value_b,
       value_a - value_b AS difference,
       CASE WHEN abs(value_a - value_b) <= tol THEN 'PASS' ELSE 'FAIL' END AS status
FROM recs
ORDER BY rec_id;

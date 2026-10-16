/* =============================================================================
   12_kpi_validation.sql   (runs on processed.*)
   Purpose: prove each KPI FORMULA is implemented correctly by computing
   it with two independent SQL methods and comparing them.
       kpi_id | kpi | scope | method_a | method_b | abs_diff | status
   These are formula checks, NOT business findings. Values describe the
   synthetic dataset only. Findings are produced later by the BQ scripts.

   Definitions used (documentation/kpi_definitions.md):
   - New patient: first recorded visit falls inside the period
   - Returning: visit in period and at least one visit before the period
   - Revenue: billing.net_amount by bill_date
   - Collections: payment_status = 'Success' only (CR-02)
   - LOS / patient-days: discharge - admission, same-day stay = 1
   - ALOS & project ARPOB: discharge-period attribution
   - Occupancy: patient-days allocated by overlap / (operating beds x days)
   - Project-defined ARPOB = IP net revenue / IP patient-days
     (NOT Apollo's methodology; Apollo discontinued ARPOB from Q1 FY26)
   - OP->IP (project-defined): IP admission 0-30 days after a qualifying OP
     visit; OP visits after 2025-03-01 excluded (right-censoring)
   ========================================================================== */
SET search_path = processed;

WITH
p_s AS (SELECT DATE '2024-04-01' AS s, DATE '2025-03-31' AS e),          -- FY2024-25
fv AS (SELECT patient_id, visit_date,
              min(visit_date) OVER (PARTITION BY patient_id) AS first_d
       FROM visits),
fy_pat_a AS (SELECT DISTINCT patient_id, first_d FROM fv, p_s WHERE visit_date BETWEEN s AND e),
fy_pat_b AS (SELECT DISTINCT v.patient_id,
                    EXISTS (SELECT 1 FROM visits x, p_s WHERE x.patient_id = v.patient_id AND x.visit_date < p_s.s)
                      AS has_prior
             FROM visits v, p_s WHERE v.visit_date BETWEEN s AND e),
paid AS (SELECT bill_id,
                sum(amount_paid) FILTER (WHERE payment_status = 'Success') AS ok_a,
                sum(CASE WHEN payment_status = 'Success' THEN amount_paid ELSE 0 END) AS ok_b
         FROM payments GROUP BY bill_id),
ip AS (SELECT v.visit_id, v.facility_id, v.admission_date, v.discharge_date,
              greatest(v.discharge_date - v.admission_date, 1) AS pd,
              v.admission_date + greatest(v.discharge_date - v.admission_date, 1) AS end_excl,
              b.net_amount
       FROM visits v JOIN billing b USING (visit_id) WHERE v.visit_type = 'IP'),
census AS (SELECT ip.facility_id, d::date AS day
           FROM ip CROSS JOIN LATERAL generate_series(ip.admission_date, ip.end_excl - 1, interval '1 day') d),
beds AS (SELECT sum(operating_bed_count) AS total_beds FROM facilities),
monthly AS (SELECT date_trunc('month', bill_date)::date AS m, sum(net_amount) AS rev
            FROM billing GROUP BY 1),
op_q AS (SELECT v.patient_id, v.visit_date
         FROM visits v, p_s
         WHERE v.visit_type = 'OP' AND v.visit_date BETWEEN p_s.s AND DATE '2025-03-01'),
kpis(kpi_id, kpi, scope, method_a, method_b) AS (
    SELECT 'K01','Total patients (>=1 visit)','All',
           (SELECT count(DISTINCT patient_id) FROM visits)::numeric,
           (SELECT count(*) FROM patients p WHERE EXISTS (SELECT 1 FROM visits v WHERE v.patient_id = p.patient_id))::numeric
    UNION ALL SELECT 'K02','New patients','FY2024-25',
           (SELECT count(*) FROM fy_pat_a, p_s WHERE first_d >= s),
           (SELECT count(*) FROM fy_pat_b WHERE NOT has_prior)
    UNION ALL SELECT 'K03','Returning patients','FY2024-25',
           (SELECT count(*) FROM fy_pat_a, p_s WHERE first_d < s),
           (SELECT count(*) FROM fy_pat_b WHERE has_prior)
    UNION ALL SELECT 'K04','Repeat patient rate (returning / total)','FY2024-25',
           (SELECT round(count(*) FILTER (WHERE first_d < s)::numeric / count(*), 6) FROM fy_pat_a, p_s),
           (SELECT round(avg(CASE WHEN has_prior THEN 1.0 ELSE 0 END), 6) FROM fy_pat_b)
    UNION ALL SELECT 'K05','IP visits','All',
           (SELECT count(*) FROM visits WHERE visit_type = 'IP'),
           (SELECT count(*) FROM billing b JOIN visits v USING (visit_id) WHERE v.visit_type = 'IP')
    UNION ALL SELECT 'K06','Net revenue (INR)','All',
           (SELECT sum(net_amount) FROM billing),
           (SELECT sum(gross_amount - discount_amount) FROM billing)
    UNION ALL SELECT 'K07','Payer mix: max abs share difference across payers','All',
           0,
           (SELECT max(abs(a - b)) FROM (
               SELECT payer_type,
                      sum(net_amount) / (SELECT sum(net_amount) FROM billing) AS a,
                      sum(net_amount) / sum(sum(net_amount)) OVER () AS b
               FROM billing GROUP BY payer_type) x)
    UNION ALL SELECT 'K08','Collections (Success only, INR)','All',
           (SELECT sum(ok_a) FROM paid), (SELECT sum(ok_b) FROM paid)
    UNION ALL SELECT 'K09','Outstanding (INR)','All',
           (SELECT sum(net_amount) FROM billing) - (SELECT sum(ok_a) FROM paid),
           (SELECT sum(b.net_amount - coalesce(p.ok_b, 0)) FROM billing b LEFT JOIN paid p USING (bill_id))
    UNION ALL SELECT 'K10','Collection rate (collected / net billed)','All',
           (SELECT round((SELECT sum(ok_a) FROM paid) / sum(net_amount), 6) FROM billing),
           (SELECT round(sum(coalesce(p.ok_b, 0)) / sum(b.net_amount), 6) FROM billing b LEFT JOIN paid p USING (bill_id))
    UNION ALL SELECT 'K11','Cancellation rate','All',
           (SELECT round(count(*) FILTER (WHERE appointment_status = 'Cancelled')::numeric / count(*), 6) FROM appointments),
           (SELECT round(avg(CASE WHEN appointment_status = 'Cancelled' THEN 1.0 ELSE 0 END), 6) FROM appointments)
    UNION ALL SELECT 'K12','No-show rate','All',
           (SELECT round(count(*) FILTER (WHERE appointment_status = 'No-show')::numeric / count(*), 6) FROM appointments),
           (SELECT round(avg(CASE WHEN appointment_status = 'No-show' THEN 1.0 ELSE 0 END), 6) FROM appointments)
    UNION ALL SELECT 'K13','Mean booking lead time (days)','All',
           (SELECT round(avg(extract(epoch FROM scheduled_datetime - booking_datetime) / 86400.0), 6) FROM appointments),
           (SELECT round(avg(date_part('day', scheduled_datetime - booking_datetime)
                             + date_part('hour', scheduled_datetime - booking_datetime) / 24.0
                             + date_part('minute', scheduled_datetime - booking_datetime) / 1440.0)::numeric, 6)
            FROM appointments)
    UNION ALL SELECT 'K14','ALOS (days, discharge attribution)','FY2024-25',
           (SELECT round(sum(pd)::numeric / count(*), 6) FROM ip, p_s WHERE discharge_date BETWEEN s AND e),
           (SELECT round(avg(pd), 6) FROM ip, p_s WHERE discharge_date BETWEEN s AND e)
    UNION ALL SELECT 'K15','Patient-days (overlap allocation)','FY2024-25',
           (SELECT count(*) FROM census, p_s WHERE day BETWEEN s AND e),
           (SELECT sum(greatest(least(end_excl, e + 1) - greatest(admission_date, s), 0)) FROM ip, p_s)
    UNION ALL SELECT 'K16','Bed occupancy (network)','FY2024-25',
           (SELECT round(count(*)::numeric / ((SELECT total_beds FROM beds) * (e - s + 1)), 6)
            FROM census, p_s WHERE day BETWEEN s AND e GROUP BY s, e),
           (SELECT round(sum(f_pd)::numeric / sum(f_bed_days), 6) FROM (
               SELECT f.facility_id,
                      (SELECT coalesce(sum(greatest(least(ip.end_excl, p_s.e + 1)
                                       - greatest(ip.admission_date, p_s.s), 0)), 0)
                       FROM ip WHERE ip.facility_id = f.facility_id) AS f_pd,
                      f.operating_bed_count * (p_s.e - p_s.s + 1) AS f_bed_days
               FROM facilities f, p_s) x)
    UNION ALL SELECT 'K17','Project-defined ARPOB (IP net / IP patient-days, INR)','FY2024-25',
           (SELECT round(sum(net_amount) / sum(pd), 6) FROM ip, p_s WHERE discharge_date BETWEEN s AND e),
           (SELECT round(sum((net_amount / pd) * pd) / sum(pd), 6) FROM ip, p_s WHERE discharge_date BETWEEN s AND e)
    UNION ALL SELECT 'K18','OP->IP 30-day conversion (project-defined)','FY2024-25',
           (SELECT round(count(DISTINCT o.patient_id) FILTER (WHERE EXISTS (
                     SELECT 1 FROM visits i WHERE i.patient_id = o.patient_id AND i.visit_type = 'IP'
                       AND i.admission_date BETWEEN o.visit_date AND o.visit_date + 30))::numeric
                   / count(DISTINCT o.patient_id), 6) FROM op_q o),
           (SELECT round(count(DISTINCT patient_id) FILTER (WHERE next_adm - visit_date <= 30)::numeric
                   / count(DISTINCT patient_id), 6)
            FROM (SELECT o.patient_id, o.visit_date,
                         (SELECT min(i.admission_date) FROM visits i
                          WHERE i.patient_id = o.patient_id AND i.visit_type = 'IP'
                            AND i.admission_date >= o.visit_date) AS next_adm
                  FROM op_q o) z)
    UNION ALL SELECT 'K19','MoM revenue growth: LAG vs self-join (max abs diff)','All months',
           0,
           (SELECT coalesce(max(abs(g_lag - g_join)), 0) FROM (
               SELECT m.m,
                      (m.rev - lag(m.rev) OVER (ORDER BY m.m)) / lag(m.rev) OVER (ORDER BY m.m) AS g_lag,
                      (m.rev - p.rev) / p.rev AS g_join
               FROM monthly m LEFT JOIN monthly p ON p.m = (m.m - interval '1 month')::date) x
            WHERE g_lag IS NOT NULL)
    UNION ALL SELECT 'K20','Running FY revenue: final running total = FY total','FY2024-25',
           (SELECT sum(net_amount) FROM billing, p_s WHERE bill_date BETWEEN s AND e),
           (SELECT max(run) FROM (SELECT sum(rev) OVER (ORDER BY m) AS run
                                  FROM monthly, p_s WHERE m BETWEEN s AND e) x)
    UNION ALL SELECT 'K21','YoY revenue growth (FY2024-25 vs FY2023-24): FILTER vs CTE join','FY',
           (SELECT round((sum(net_amount) FILTER (WHERE bill_date >= DATE '2024-04-01')
                        - sum(net_amount) FILTER (WHERE bill_date <  DATE '2024-04-01'))
                       / sum(net_amount) FILTER (WHERE bill_date <  DATE '2024-04-01'), 6) FROM billing),
           (SELECT round((c.r - p.r) / p.r, 6)
            FROM (SELECT sum(net_amount) r FROM billing WHERE bill_date >= DATE '2024-04-01') c,
                 (SELECT sum(net_amount) r FROM billing WHERE bill_date <  DATE '2024-04-01') p)
)
SELECT kpi_id, kpi, scope, method_a, method_b,
       abs(method_a - method_b) AS abs_diff,
       CASE WHEN abs(method_a - method_b) <= 0.000001 THEN 'PASS' ELSE 'FAIL' END AS status
FROM kpis
ORDER BY kpi_id;

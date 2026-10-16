/* =============================================================================
   07_generate_billing.sql   (Phase 7a)
   Generates raw.billing - exactly one bill per visit.

   Components (A-10, A-11, A-12; INR; portfolio assumptions, not tariffs):
     consultation : OP/Day-care = doctor fee; ER = facility ER fee;
                    IP = doctor fee x patient-days            (x FY2 uplift)
     procedure    : SUM(visit_procedures.charged_amount)      (already uplifted)
     room         : IP only = facility room rate x patient-days (x FY2 uplift)
     pharmacy     : IP = patient-days x U(1500,4000); Day-care U(1000,8000);
                    ER 60% U(300,2500); OP 40% U(200,3000)
     diagnostics  : lab/imaging not itemised as procedures. IP = patient-days x
                    U(1000,3000) + U(1000,5000); ER 70% U(800,5000);
                    Day-care 50% U(500,4000); OP (non-Radiology) 35% U(500,6000)
   gross = sum of components (each rounded to 2 dp first)
   Payer mix by visit type (A-13); discount rule by payer (A-14):
     Corporate U(5%,10%) of gross; Self-pay 5% of bills get 5%; others 0.
   net = gross - discount.  bill_date = discharge_date (IP) else visit_date.
   ========================================================================== */

DROP TABLE IF EXISTS tmp_bill;
CREATE TEMP TABLE tmp_bill AS
WITH base AS (
    SELECT v.visit_id, v.visit_type, v.department_id, v.facility_id,
           CASE WHEN v.visit_type = 'IP' THEN v.discharge_date ELSE v.visit_date END AS bill_date,
           CASE WHEN v.visit_type = 'IP'
                THEN greatest(v.discharge_date - v.admission_date, 1) ELSE 0 END      AS patient_days,
           d.consultation_fee,
           fp.room_rate_per_day,
           fp.er_fee
    FROM raw.visits v
    JOIN raw.doctors d            ON d.doctor_id = v.doctor_id
    JOIN gen.v_facility_params fp ON fp.facility_id = v.facility_id
),
f AS (
    SELECT b.*,
           CASE WHEN b.bill_date >= DATE '2024-04-01'
                THEN 1 + (SELECT fy2_tariff_uplift FROM gen.v_params) ELSE 1 END AS uplift,
           coalesce((SELECT sum(vp.charged_amount) FROM raw.visit_procedures vp
                     WHERE vp.visit_id = b.visit_id), 0)                     AS proc_total
    FROM base b
)
SELECT f.visit_id, f.visit_type, f.bill_date,
       round((CASE f.visit_type
                WHEN 'ER' THEN f.er_fee
                WHEN 'IP' THEN f.consultation_fee * f.patient_days
                ELSE f.consultation_fee END * f.uplift)::numeric, 2)                   AS consultation_charges,
       f.proc_total                                                                    AS procedure_charges,
       round((CASE WHEN f.visit_type = 'IP'
                   THEN f.room_rate_per_day * f.patient_days * f.uplift ELSE 0 END)::numeric, 2)
                                                                                       AS room_charges,
       round((CASE f.visit_type
                WHEN 'IP'       THEN f.patient_days * gen.ur('bill:ph:' || f.visit_id, 1500, 4000)
                WHEN 'Day-care' THEN gen.ur('bill:ph:' || f.visit_id, 1000, 8000)
                WHEN 'ER'       THEN CASE WHEN gen.u('bill:phy:' || f.visit_id) < 0.60
                                          THEN gen.ur('bill:ph:' || f.visit_id, 300, 2500) ELSE 0 END
                ELSE                 CASE WHEN gen.u('bill:phy:' || f.visit_id) < 0.40
                                          THEN gen.ur('bill:ph:' || f.visit_id, 200, 3000) ELSE 0 END
              END)::numeric, 2)                                                        AS pharmacy_charges,
       round((CASE
                WHEN f.visit_type = 'IP' THEN f.patient_days * gen.ur('bill:dx:' || f.visit_id, 1000, 3000)
                                              + gen.ur('bill:dx2:' || f.visit_id, 1000, 5000)
                WHEN f.visit_type = 'ER' THEN CASE WHEN gen.u('bill:dxy:' || f.visit_id) < 0.70
                                              THEN gen.ur('bill:dx:' || f.visit_id, 800, 5000) ELSE 0 END
                WHEN f.visit_type = 'Day-care' THEN CASE WHEN gen.u('bill:dxy:' || f.visit_id) < 0.50
                                              THEN gen.ur('bill:dx:' || f.visit_id, 500, 4000) ELSE 0 END
                WHEN f.department_id = 'DEP14' THEN 0
                ELSE CASE WHEN gen.u('bill:dxy:' || f.visit_id) < 0.35
                          THEN gen.ur('bill:dx:' || f.visit_id, 500, 6000) ELSE 0 END
              END)::numeric, 2)                                                        AS diagnostics_charges,
       -- payer by visit type (A-13)
       (SELECT CASE WHEN u < m.s THEN 'Self-pay'
                    WHEN u < m.s + m.i THEN 'Insurance-TPA'
                    WHEN u < m.s + m.i + m.c THEN 'Corporate'
                    ELSE 'Govt scheme' END
        FROM (SELECT gen.u('bill:payer:' || f.visit_id) AS u) x,
             (VALUES ('OP',0.72,0.12,0.10), ('ER',0.60,0.25,0.08),
                     ('Day-care',0.45,0.35,0.10), ('IP',0.35,0.40,0.12)) AS m(vt, s, i, c)
        WHERE m.vt = f.visit_type)                                                     AS payer_type
FROM f;

INSERT INTO raw.billing
SELECT 'BIL' || lpad(row_number() OVER (ORDER BY g.bill_date, g.visit_id)::text, 6, '0'),
       g.visit_id, g.bill_date,
       g.consultation_charges, g.procedure_charges, g.room_charges,
       g.pharmacy_charges, g.diagnostics_charges,
       g.gross_amount,
       g.discount_amount,
       g.gross_amount - g.discount_amount,
       g.payer_type
FROM (
    SELECT t.*,
           t.consultation_charges + t.procedure_charges + t.room_charges
             + t.pharmacy_charges + t.diagnostics_charges AS gross_amount,
           round(CASE
                   WHEN t.payer_type = 'Corporate'
                   THEN (t.consultation_charges + t.procedure_charges + t.room_charges
                         + t.pharmacy_charges + t.diagnostics_charges)
                        * gen.ur('bill:disc:' || t.visit_id, 0.05, 0.10)::numeric
                   WHEN t.payer_type = 'Self-pay' AND gen.u('bill:goodwill:' || t.visit_id) < 0.05
                   THEN (t.consultation_charges + t.procedure_charges + t.room_charges
                         + t.pharmacy_charges + t.diagnostics_charges) * 0.05
                   ELSE 0 END, 2) AS discount_amount
    FROM tmp_bill t
) g;

SELECT count(*) AS bills,
       (SELECT count(*) FROM raw.visits) AS visits,
       count(*) FILTER (WHERE net_amount <> gross_amount - discount_amount) AS net_mismatch,
       count(*) FILTER (WHERE gross_amount <> consultation_charges + procedure_charges + room_charges
                                             + pharmacy_charges + diagnostics_charges) AS gross_mismatch
FROM raw.billing;

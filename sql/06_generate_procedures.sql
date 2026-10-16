/* =============================================================================
   06_generate_procedures.sql   (Phase 6: procedures performed)
   Generates raw.visit_procedures. (The procedure catalogue itself was created
   in 02_reference_data.sql.)

   Rules (A-07, A-08 in documentation/generation_assumptions.md):
   - Procedure must belong to the visit's department AND be flagged for the
     visit's care setting in gen.v_procedure_catalogue.
   - IP: 0/1/2 procedures (10% / 70% / 20%); date within [admission, discharge].
   - Day-care: 1 or 2 procedures (75% / 25%) - always at least one.
   - OP: Radiology & Imaging visits 90% get one imaging study; other OP 12%.
   - ER: 30% get one emergency procedure.
   - Quantity: 1, except Therapy Session in IP (1-3, bounded by patient-days).
   - charged_amount = quantity x standard_price x U(0.95,1.05)
                      x (1 + FY2 tariff uplift) when procedure_date >= 2024-04-01
   Which procedures are picked: equal-weight random draw (no procedure is
   favoured), so procedure rankings are Emergent except for price ranges.
   ========================================================================== */

DROP TABLE IF EXISTS tmp_vp;
CREATE TEMP TABLE tmp_vp AS
WITH v AS (
    SELECT v.*,
           CASE v.visit_type
             WHEN 'IP' THEN CASE WHEN gen.u('vp:n:' || v.visit_id) < 0.10 THEN 0
                                 WHEN gen.u('vp:n:' || v.visit_id) < 0.80 THEN 1 ELSE 2 END
             WHEN 'Day-care' THEN CASE WHEN gen.u('vp:n:' || v.visit_id) < 0.75 THEN 1 ELSE 2 END
             WHEN 'OP' THEN CASE WHEN gen.u('vp:n:' || v.visit_id)
                                      < CASE WHEN v.department_id = 'DEP14' THEN 0.90 ELSE 0.12 END
                                 THEN 1 ELSE 0 END
             WHEN 'ER' THEN CASE WHEN gen.u('vp:n:' || v.visit_id) < 0.30 THEN 1 ELSE 0 END
           END AS n_proc
    FROM raw.visits v
),
cand AS (
    SELECT v.visit_id, v.visit_type, v.visit_date, v.admission_date, v.discharge_date, v.n_proc,
           p.procedure_id, p.procedure_category, p.standard_price,
           row_number() OVER (PARTITION BY v.visit_id
                              ORDER BY gen.u('vp:pick:' || v.visit_id || ':' || p.procedure_id),
                                       p.procedure_id) AS pick_rank
    FROM v
    JOIN raw.procedures p ON p.department_id = v.department_id
    JOIN gen.v_procedure_catalogue c ON c.procedure_name = p.procedure_name
    WHERE v.n_proc > 0
      AND CASE v.visit_type WHEN 'IP' THEN c.ip WHEN 'Day-care' THEN c.dc
                            WHEN 'OP' THEN c.op ELSE c.er END
)
SELECT c.visit_id, c.procedure_id, c.pick_rank,
       CASE WHEN c.visit_type = 'IP'
            THEN c.admission_date
                 + gen.ri('vp:date:' || c.visit_id || ':' || c.procedure_id, 0,
                          c.discharge_date - c.admission_date)
            ELSE c.visit_date END AS procedure_date,
       CASE WHEN c.visit_type = 'IP' AND c.procedure_category = 'Therapy Session'
            THEN gen.ri('vp:qty:' || c.visit_id || ':' || c.procedure_id, 1,
                        least(greatest(c.discharge_date - c.admission_date, 1), 3))
            ELSE 1 END AS quantity,
       c.standard_price
FROM cand c
WHERE c.pick_rank <= c.n_proc;

INSERT INTO raw.visit_procedures
SELECT 'VPR' || lpad(row_number() OVER (ORDER BY t.procedure_date, t.visit_id, t.pick_rank)::text, 6, '0'),
       t.visit_id,
       t.procedure_id,
       t.procedure_date,
       t.quantity,
       round((t.quantity * t.standard_price
              * gen.ur('vp:price:' || t.visit_id || ':' || t.procedure_id, 0.95, 1.05)
              * CASE WHEN t.procedure_date >= DATE '2024-04-01'
                     THEN 1 + (SELECT fy2_tariff_uplift FROM gen.v_params) ELSE 1 END
             )::numeric, 2)
FROM tmp_vp t;

SELECT v.visit_type,
       count(DISTINCT vp.visit_id) AS visits_with_procedures,
       count(*) AS procedure_lines
FROM raw.visit_procedures vp
JOIN raw.visits v USING (visit_id)
GROUP BY v.visit_type
UNION ALL
SELECT 'TOTAL', count(DISTINCT visit_id), count(*) FROM raw.visit_procedures;

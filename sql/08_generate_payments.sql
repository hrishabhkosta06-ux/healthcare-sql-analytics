/* =============================================================================
   08_generate_payments.sql   (Phase 7b)
   Generates raw.payments (one bill -> zero, one or many payment rows).

   Settlement behaviour by payer (A-15; portfolio assumptions, not Apollo data):
     Self-pay  OP/ER/Day-care : 97% pay in full on bill_date, 3% partial (30-90%)
     Self-pay  IP             : 2 instalments (50-70% on bill_date, remainder
                                0-15 days later); 3% never pay the remainder
     Insurance-TPA            : settled 15-75 days after bill; 70% in full,
                                30% with deductions (85-99%)
     Corporate                : settled 30-90 days after bill, in full
     Govt scheme              : settled 30-120 days after bill; 50% in full,
                                50% at 80-99%
   Any settlement that would fall after 2025-03-31 is not recorded (dataset
   cutoff) -> bill remains outstanding. This is the RIGHT-CENSORING that the
   collection-cohort analysis must account for.

   payment_status (CR-02): 2% of self-pay digital payments (UPI/Card/Net
   Banking) are preceded by a FAILED attempt of the same amount on the same
   date. Failed rows never count toward collections.
   Invariant: SUM(Success) per bill <= net_amount  (validated in 09).
   ========================================================================== */

DROP TABLE IF EXISTS tmp_pay;
CREATE TEMP TABLE tmp_pay (
    bill_id      varchar(10),
    seq          int,           -- order of rows within a bill
    payment_date date,
    amount_paid  numeric(12,2),
    payment_mode varchar(25),
    payment_status varchar(10)
);

-- Self-pay, non-IP: one payment (full or partial) on bill_date
INSERT INTO tmp_pay
SELECT b.bill_id, 2, b.bill_date,
       CASE WHEN gen.u('pay:sp:full:' || b.bill_id) < 0.97 THEN b.net_amount
            ELSE round(b.net_amount * gen.ur('pay:sp:part:' || b.bill_id, 0.30, 0.90)::numeric, 2) END,
       CASE WHEN gen.u('pay:mode:' || b.bill_id) < 0.30 THEN 'Cash'
            WHEN gen.u('pay:mode:' || b.bill_id) < 0.75 THEN 'UPI'
            ELSE 'Card' END,
       'Success'
FROM raw.billing b JOIN raw.visits v USING (visit_id)
WHERE b.payer_type = 'Self-pay' AND v.visit_type <> 'IP';

-- Self-pay, IP: instalment 1 on bill_date
INSERT INTO tmp_pay
SELECT b.bill_id, 2, b.bill_date,
       round(b.net_amount * gen.ur('pay:ip1:' || b.bill_id, 0.50, 0.70)::numeric, 2),
       CASE WHEN gen.u('pay:mode:' || b.bill_id) < 0.15 THEN 'Cash'
            WHEN gen.u('pay:mode:' || b.bill_id) < 0.50 THEN 'UPI'
            WHEN gen.u('pay:mode:' || b.bill_id) < 0.80 THEN 'Card'
            ELSE 'Net Banking' END,
       'Success'
FROM raw.billing b JOIN raw.visits v USING (visit_id)
WHERE b.payer_type = 'Self-pay' AND v.visit_type = 'IP';

-- Self-pay, IP: instalment 2 = exact remainder (97%), within cutoff
INSERT INTO tmp_pay
SELECT b.bill_id, 4, b.bill_date + gen.ri('pay:ip2d:' || b.bill_id, 0, 15),
       b.net_amount - p1.amount_paid,
       CASE WHEN gen.u('pay:mode2:' || b.bill_id) < 0.15 THEN 'Cash'
            WHEN gen.u('pay:mode2:' || b.bill_id) < 0.50 THEN 'UPI'
            WHEN gen.u('pay:mode2:' || b.bill_id) < 0.80 THEN 'Card'
            ELSE 'Net Banking' END,
       'Success'
FROM raw.billing b
JOIN raw.visits v USING (visit_id)
JOIN tmp_pay p1 ON p1.bill_id = b.bill_id AND p1.seq = 2
WHERE b.payer_type = 'Self-pay' AND v.visit_type = 'IP'
  AND gen.u('pay:ip2y:' || b.bill_id) < 0.97
  AND b.bill_date + gen.ri('pay:ip2d:' || b.bill_id, 0, 15) <= DATE '2025-03-31'
  AND b.net_amount - p1.amount_paid > 0;

-- Institutional payers: single settlement after a lag (censored at cutoff)
INSERT INTO tmp_pay
SELECT s.bill_id, 2, s.pay_date, s.amount, s.mode, 'Success'
FROM (
    SELECT b.bill_id,
           b.bill_date + CASE b.payer_type
                           WHEN 'Insurance-TPA' THEN gen.ri('pay:lag:' || b.bill_id, 15, 75)
                           WHEN 'Corporate'     THEN gen.ri('pay:lag:' || b.bill_id, 30, 90)
                           ELSE                      gen.ri('pay:lag:' || b.bill_id, 30, 120) END AS pay_date,
           CASE b.payer_type
             WHEN 'Insurance-TPA' THEN CASE WHEN gen.u('pay:full:' || b.bill_id) < 0.70 THEN b.net_amount
                  ELSE round(b.net_amount * gen.ur('pay:ded:' || b.bill_id, 0.85, 0.99)::numeric, 2) END
             WHEN 'Corporate'     THEN b.net_amount
             ELSE                      CASE WHEN gen.u('pay:full:' || b.bill_id) < 0.50 THEN b.net_amount
                  ELSE round(b.net_amount * gen.ur('pay:ded:' || b.bill_id, 0.80, 0.99)::numeric, 2) END
           END AS amount,
           CASE b.payer_type WHEN 'Insurance-TPA' THEN 'Insurance Settlement'
                             WHEN 'Corporate'     THEN 'Corporate Settlement'
                             ELSE                      'Govt Scheme Settlement' END AS mode
    FROM raw.billing b
    WHERE b.payer_type IN ('Insurance-TPA','Corporate','Govt scheme')
) s
WHERE s.pay_date <= DATE '2025-03-31';

-- Failed attempts (CR-02): precede 2% of self-pay digital payments, same date/amount
INSERT INTO tmp_pay
SELECT p.bill_id, p.seq - 1, p.payment_date, p.amount_paid, p.payment_mode, 'Failed'
FROM tmp_pay p
WHERE p.payment_status = 'Success'
  AND p.payment_mode IN ('UPI','Card','Net Banking')
  AND gen.u('pay:fail:' || p.bill_id || ':' || p.seq) < 0.02;

INSERT INTO raw.payments
SELECT 'PAY' || lpad(row_number() OVER (ORDER BY t.payment_date, t.bill_id, t.seq)::text, 6, '0'),
       t.bill_id, t.payment_date, t.amount_paid, t.payment_mode, t.payment_status
FROM tmp_pay t;

/* ---------------------------------------------------------------------------
   DQ-03: ~4% of payer labels written inconsistently (raw only).
   Injected AFTER payments so generation logic used clean labels.
   ------------------------------------------------------------------------ */
UPDATE raw.billing
SET payer_type = CASE payer_type
        WHEN 'Self-pay'      THEN gen.pick('dq03v:' || bill_id, ARRAY['self pay','Self Pay','SELF-PAY'])
        WHEN 'Insurance-TPA' THEN gen.pick('dq03v:' || bill_id, ARRAY['insurance tpa','Insurance TPA','INSURANCE-TPA'])
        WHEN 'Corporate'     THEN gen.pick('dq03v:' || bill_id, ARRAY['corporate','CORPORATE','Corporate '])
        ELSE                      gen.pick('dq03v:' || bill_id, ARRAY['Govt Scheme','govt scheme','Government Scheme'])
    END
WHERE gen.u('dq03:' || bill_id) < 0.04;

SELECT count(*) AS payment_rows,
       count(*) FILTER (WHERE payment_status = 'Failed') AS failed_attempts,
       round(count(*)::numeric / (SELECT count(*) FROM raw.billing), 3) AS rows_per_bill,
       (SELECT count(*) FROM raw.billing b
        WHERE NOT EXISTS (SELECT 1 FROM raw.payments p WHERE p.bill_id = b.bill_id)) AS bills_without_payment
FROM raw.payments;

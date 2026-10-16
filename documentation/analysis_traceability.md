# Analysis Traceability

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

This project uses a deterministic synthetic healthcare dataset generated in PostgreSQL for portfolio and analytical learning purposes. It does not represent actual Apollo Hospitals operational or financial data.

**Data source:**
- Schema `processed` only (seed 20250331).
- 9,003 processed registered patients, of whom 8,700 had at least one visit; 303 registered patients had no visit during the analysis window.
- 40,866 appointments · 43,714 visits · 43,714 bills · 45,058 payments.
- Raw schema: 9,121 patient records (118 duplicate-like records merged in cleaning).

**Chain for every BQ:**
- Each BQ runs: BQ → SQL file / section → KPI → executed result → validation → finding (`analytical_findings.md`).
- Each analytics SQL file ends with validation checks. Reported analytics checks: 29 named validations plus 4 FY boundary tests = 33 PASS.

**Finding type:**
- *Emergent* — not directly set by a generator parameter.
- *Assumption-driven* — materially explained by a documented generation assumption (A-xx in `generation_assumptions.md` §4).
- Finding type is assigned to the principal interpretation of each BQ. Individual observations within a BQ may still have an assumption-driven component or caveat. Where this occurs, the relevant assumption is explicitly identified in the interpretation or limitation (e.g. BQ-04: principally Emergent; Emergency Medicine's higher repeat rate has an A-03 mechanical component).

**Default revenue basis:**
- Net revenue = `billing.net_amount` by `bill_date`.
- Exceptions are named in the table.

| BQ | Business question | SQL file | Section | KPI | Methodology | Finding type | Assumption |
|---|---|---|---|---|---|---|---|
| BQ-01 | How many unique patients were served per month, per facility and per visit type? | 13_patient_analytics.sql | BQ-01 + summary | Unique patients, visits | COUNT DISTINCT by month × facility × visit_type; FY summary | Assumption-driven | A-01, A-05 |
| BQ-02 | What is the patient distribution by age band and gender, and how does it differ by department? | 13_patient_analytics.sql | BQ-02 + summary | Patients by age group × gender | Age at first visit to the department (CASE age bands); one row per patient-department | Assumption-driven | A-02 |
| BQ-03 | What share of each month's patients are new vs returning? | 13_patient_analytics.sql | BQ-03 | New, returning, returning % | First-visit CTE; new = first visit in month; returning = first visit before month (project definitions; left-censoring) | Assumption-driven | A-01, A-05 |
| BQ-04 | What is the repeat patient rate by department? | 13_patient_analytics.sql | BQ-04 + network | Returning ÷ total patients | FY2024-25 patients per department; returning = any visit before 1 Apr 2024 | Emergent | (ER level partly A-03) |
| BQ-05 | What is the median interval between consecutive visits for returning patients? | 13_patient_analytics.sql | BQ-05 | Median days between visits | LAG over distinct visit dates; PERCENTILE_CONT(0.5) | Assumption-driven | A-05 |
| BQ-06 | What share of total net revenue does each patient spend decile account for? | 13_patient_analytics.sql | BQ-06 | Decile revenue share % | Patient spend CTE → NTILE(10) → SUM per decile (analytical segmentation only) | Emergent | — |
| BQ-07 | Which departments rank highest by visits, net revenue and revenue per visit? | 14_department_analytics.sql | BQ-07 | Visits, net revenue, revenue/visit + ranks | Aggregate per department → RANK on each metric | Emergent | — |
| BQ-08 | What is each department's % contribution to total revenue, and how did it shift FY2023-24 → FY2024-25? | 14_department_analytics.sql | BQ-08 | Revenue share %, change in pp | SUM … FILTER by FY; share via SUM() OVER () | Emergent | — |
| BQ-09 | What is the OP vs IP revenue split by department? | 14_department_analytics.sql | BQ-09 + network | OP / IP / Day-care / ER revenue and share | Conditional SUM (FILTER) by visit_type | Assumption-driven | A-07, A-08, A-11 |
| BQ-10 | What is the 30-day OP→IP conversion rate by department? | 14_department_analytics.sql | BQ-10 + network | Converted ÷ OP patients | Project-defined: IP admission 0–30 days after qualifying OP (≤ 1 Mar 2025); OP-department attribution, each department's denominator computed independently (a patient can count in several departments); network rate uses distinct patients; LEFT JOIN + MAX flag | Assumption-driven | A-21 |
| BQ-11 | Who are the top 3 doctors by revenue within each department? | 15_doctor_analytics.sql | BQ-11 | Doctor net revenue, rank | RANK() PARTITION BY department, keep ≤ 3 | Assumption-driven | A-06, A-18 |
| BQ-12 | Which doctors generate revenue above their department average? | 15_doctor_analytics.sql | BQ-12 + summary | Doctor vs department average | Doctor revenue CTE + department average CTE, JOIN, filter | Assumption-driven | A-06 |
| BQ-13 | What is the average monthly visit load per doctor, by department? | 15_doctor_analytics.sql | BQ-13 | Visits per active month | Visits ÷ active months (join-month adjusted), averaged per department | Assumption-driven | A-04, A-06 |
| BQ-14 | What share of each department's revenue comes from its top doctor? | 15_doctor_analytics.sql | BQ-14 | Top-doctor share %, equal-share benchmark | ROW_NUMBER = 1 per department ÷ department revenue | Assumption-driven | A-06, A-18 |
| BQ-15 | How does the no-show rate vary by doctor? | 15_doctor_analytics.sql | BQ-15 + spread | No-show rate % | COUNT FILTER ÷ COUNT; HAVING ≥ 100 bookings (threshold fixed before running) | Assumption-driven | A-16, D-02 |
| BQ-16 | Which procedures have the highest volume and the highest revenue? | 16_procedure_analytics.sql | BQ-16 + category | Units, procedure revenue (gross), ranks | Line-level SUM(quantity), SUM(charged_amount); RANK | Assumption-driven | A-07, A-08 |
| BQ-17 | What is each procedure's % contribution to procedure revenue? | 16_procedure_analytics.sql | BQ-17 + context | Contribution %, cumulative % | charged_amount share (gross, line level — no bill amount allocated to lines); running cumulative SUM | Assumption-driven | A-08 |
| BQ-18 | How does procedure volume trend month over month? | 16_procedure_analytics.sql | BQ-18 | Monthly units, MoM % | GROUP BY month → LAG | Assumption-driven | A-01, A-05, A-07 |
| BQ-19 | Which procedures are most associated with IP admissions? | 16_procedure_analytics.sql | BQ-19 | IP share of units % | IP units ÷ all units; HAVING ≥ 30 units (fixed before running); descriptive | Assumption-driven | A-07 |
| BQ-20 | What is monthly and quarterly net revenue, with MoM, QoQ and YoY growth? | 17_revenue_analytics.sql | BQ-20a/b/c | Net revenue, MoM, QoQ, YoY | GROUP BY month / FY quarter → LAG(1), LAG(12), LAG(4) | Assumption-driven | A-01, A-05, A-08 |
| BQ-21 | What is the revenue mix by charge component? | 17_revenue_analytics.sql | BQ-21 | Component share of gross % | SUM of 5 components ÷ gross (basis: gross); by visit type | Assumption-driven | A-08, A-10, A-11, A-12 |
| BQ-22 | What are revenue and average bill value by payer type? | 17_revenue_analytics.sql | BQ-22 | Net revenue, share, average net bill | GROUP BY payer_type; SUM() OVER () shares | Assumption-driven | A-13 |
| BQ-23 | What is the average discount rate by department and payer type? | 17_revenue_analytics.sql | BQ-23 + summary | SUM(discount) ÷ SUM(gross) | Ratio of sums; NULLIF on gross | Assumption-driven | A-14 |
| BQ-24 | What are the collection rate and outstanding amount by payer type? | 17_revenue_analytics.sql | BQ-24a/b | Collected, outstanding, collection rate | Success-only payments aggregated per bill first, LEFT JOIN billing; quarter-cohort view for right-censoring | Assumption-driven | A-15 |
| BQ-25 | What are cancellation and no-show rates by month, department and booking channel? | 18_operational_analytics.sql | BQ-25a–d | Cancellation %, no-show % | COUNT FILTER ÷ COUNT by dimension | Assumption-driven | A-16, D-02 |
| BQ-26 | How does the no-show rate differ across booking lead-time buckets? | 18_operational_analytics.sql | BQ-26 | No-show % by bucket | Lead days = scheduled date − booking date; CASE buckets; association only | Assumption-driven | A-17, D-02 |
| BQ-27 | What is ALOS by department and facility? | 18_operational_analytics.sql | BQ-27 (3 queries) | ALOS (days) | SUM(GREATEST(discharge − admission, 1)) ÷ discharges; discharge attribution | Assumption-driven | A-19 |
| BQ-28 | What are bed occupancy and project-defined ARPOB by facility and city tier? | 18_operational_analytics.sql | BQ-28 facility + tier | Occupancy %, project-defined ARPOB (₹) | Occupancy: FY-overlap patient-days ÷ (beds × days); ARPOB: IP net ÷ IP patient-days of stays discharged in FY. Not Apollo's methodology | Assumption-driven | A-10, A-11, A-18, A-19 |
| BQ-29 | How does cumulative FY revenue compare with the prior FY at the same point in the year? | 19_trend_analytics.sql | BQ-29 | Cumulative net revenue, YTD growth % | Running SUM() OVER (PARTITION BY FY ORDER BY FY month); self-join on FY month | Assumption-driven | A-01, A-05, A-08 |
| BQ-30 | Peak and trough months: which months show peaks or troughs in visits in both FYs? | 19_trend_analytics.sql | BQ-30 + consistency | Visit rank in FY (revenue rank shown alongside) | RANK within FY; top/bottom 3 flags; both-FY consistency check. Descriptive, no seasonality claimed | Assumption-driven | A-01, A-05, A-20 |

**Coverage:** 30/30 BQs, each mapped once. 4 Emergent, 26 Assumption-driven.

**BQ-30 definition:** the primary BQ-30 ranking is visit-based as specified in the business question. Revenue peak/trough rankings are reported as supplementary context and do not change the BQ definition.

---

## Grain, validation, result and limitation register

Each row adds the analytical grain, the validation that protects the result, the key executed result and the principal limitation. Full interpretation is in [`analytical_findings.md`](analytical_findings.md). File-level validation IDs (V13-x … V19-x) are the PASS checks at the end of each SQL file (29 named analytics validations + 4 FY boundary tests = 33/33 reported PASS). Pipeline validation suites: `09` (42/42), `11` (27/27), `12` (21/21).

| BQ | Grain | Validation | Key actual result | Principal finding / limitation |
|---|---|---|---|---|
| BQ-01 | month × facility × visit type | V13-1; RC01 | Unique patients 4,184 (FY23-24) → 7,707 (FY24-25); visits 16,954 → 26,760 | Volume ramps as the patient base accumulates / patients can appear in several visit-type rows |
| BQ-02 | department × age group × gender | V13-1 | 0–17 = 17.3% … 75+ = 13.7%; F 4,426 / M 4,182 / Other 92 | Mix reflects generator demographics / age at first visit per department |
| BQ-03 | month | V13-3 (new + returning = total) | Returning share 0% (Apr 2023) → 81–82% (Jan–Mar 2025) | Rise is mostly left-censoring / no pre-2023 history |
| BQ-04 | department (FY2024-25) | RC04–RC05; K02–K04 | Network 41.4%; departments 37.6%–58.1% | Spread is emergent; ER level partly A-03 / "returning" = any prior visit |
| BQ-05 | consecutive visit dates per patient | No dedicated check; input dates covered by `09` T04 (visit dates inside window) | Median 32 days; mean 53.6; IQR 13–70 | Right-skewed gaps / same-day encounters merged |
| BQ-06 | patient spend decile | V13-2 (deciles = net revenue) | Top decile 51.2%; top two 74.4%; bottom five 3.4% | Revenue concentrated in a high-spend segment / analytical segmentation only |
| BQ-07 | department | V14-1; V14-5 (14 distinct ranks) | Revenue #1 Orthopaedics; visits #1 Nephrology; revenue per visit #1 O&G | Volume ≠ value / synthetic tariffs |
| BQ-08 | department × FY | V14-2 | Largest shifts: Cardiothoracic +1.68 pp; Orthopaedics −3.26 pp | Shifts without a growth parameter / two FYs only |
| BQ-09 | department × visit type | V14-1; RC16 | IP 85.5% of revenue from 16.1% of visits | Inpatient-led revenue / synthetic pricing |
| BQ-10 | qualifying-OP department; network distinct patients | V14-3 (censoring); V14-4 (two methods agree) | Network 31.2%; O&G 48.4% … Radiology 9.6% | Recovers A-21 referral design / project-defined; department denominators independent |
| BQ-11 | doctor within department | V15-1; V15-3 | Facility A doctor ranks #1 in 9 of 14 departments | Tracks bed allocation and A-06 / synthetic productivity |
| BQ-12 | doctor | V15-1 | 38 of 72 doctors above department average | Distribution of A-06 weights / small departments unstable |
| BQ-13 | doctor → department | V15-3; V15-4 (active months 1–24) | Nephrology 40.4 … O&G 12.6 visits per doctor-month | Demand weights and roster / no slot-capacity model |
| BQ-14 | department | V15-2 (one top doctor each) | Top-doctor share 19.4%–39.9% | Higher concentration in 3–4-doctor departments / partly mechanical |
| BQ-15 | doctor (≥ 100 bookings) | V18-1 (indirect appointment-status reconciliation; no dedicated doctor-level rate validation) | 64 doctors; 7.3%–15.6%; network 11.8% | Sampling variation (D-02) / descriptive only |
| BQ-16 | procedure; category | V16-1; V16-2 | Top revenue: Craniotomy; top volume: IV Fluid; Major Surgery 70.9% of revenue from 15.8% of units | Price ranges drive value / gross basis |
| BQ-17 | procedure | V16-2; V16-4 (100%) | Top 12 = 64.6%; top 20 = 86.1%; procedures 58.4% of gross | Short surgical list dominates / no net allocation invented |
| BQ-18 | month | V16-3 | 529 (Apr 2023) → 943 (Mar 2025) units; MoM −11.2% to +20.4% | Ramp plus noise / no designed seasonality |
| BQ-19 | procedure (≥ 30 units) | V16-1 | 20 procedures 100% IP; Chemotherapy 84.0% IP | Care-setting flags (A-07) / association, not causation |
| BQ-20 | month; FY quarter; FY | V17-1; RC20–RC21; K19–K21 | FY net +9.9% vs visits +57.8%; average bill ₹41.9k → ₹29.1k | Consistent with capacity-bound IP + OP growth / early YoY inflated by ramp |
| BQ-21 | component; visit type | V17-3 | Procedures 58.4%, room 20.2%, diagnostics 8.6%, pharmacy 8.4%, consultation 4.5% | Tariff structure / gross basis |
| BQ-22 | payer | V17-2 | Self-pay 64.4% of bills / 38.8% of revenue; Insurance 18.2% / 38.2% | Payer mix by visit type (A-13) |
| BQ-23 | department × payer | V17-3 | Corporate 7.52%; Self-pay 0.24%; others 0% | Discount rule (A-14) |
| BQ-24 | payer; billing-quarter cohort | V17-4; V17-5; V17-6; RC13–RC15 | Collected ₹1,387.1M; outstanding ₹101.4M; latest cohort 61.1% | Settlement lags (A-15) / right-censoring |
| BQ-25 | status; month; department; channel | V18-1; RC02 | Completed 76.5%, Cancelled 11.7%, No-show 11.8% | Independent base rates (D-02) |
| BQ-26 | lead-time bucket | V18-2 | No-show 11.2%–12.2% across buckets | No designed effect / association only |
| BQ-27 | department; facility; FY | RC23; K14 | ALOS 4.83 (FY23-24), 5.05 (FY24-25) | LOS bands (A-19) / same-day = 1 day |
| BQ-28 | facility × FY; tier × FY | V18-3 (census ≤ beds); V18-4; K16–K17; V18-5 (indirect IP billing-count check) | Occupancy 67.4%–71.2%; ARPOB Metro ₹39.6k–40.3k, Non-metro ₹28.1k–29.3k | Synthetic capacity and tariffs / project-defined ARPOB, not Apollo's |
| BQ-29 | FY month | V19-1; K20 | YTD lead +33.5% (Apr) → +9.9% (Mar) | Ramp-up base year / two FYs |
| BQ-30 | month within FY (visits primary) | V19-2; FY boundary test (4/4 PASS) | Apr–Jun bottom-3 and Jan, Mar top-3 in both FYs | Consistent with patient-base ramp; not evidence of seasonality |

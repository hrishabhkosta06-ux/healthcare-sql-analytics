# Analytical Findings

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

> This project uses a deterministic synthetic healthcare dataset generated in PostgreSQL for portfolio and analytical learning purposes. It does not represent actual Apollo Hospitals operational or financial data. Every number below comes from executing `sql/13`–`sql/19` against the `processed` schema (seed 20250331). All findings describe the synthetic project dataset only.

**Key scope figures:**
- Window: 1 Apr 2023 – 31 Mar 2025 (FY2023-24, FY2024-25).
- Net revenue: ₹1,488.4M (FY2023-24 ₹709.0M; FY2024-25 ₹779.5M).
- 43,714 visits.
- 9,003 processed registered patients, of whom 8,700 had at least one visit; 303 registered patients had no visit during the analysis window (contact was a booking that was cancelled or not attended).

**Finding types:**
- **Emergent** — not directly set by a generator parameter.
- **Assumption-driven** — materially explained by a documented generation assumption (`generation_assumptions.md` §4–5). An assumption-driven result shows that the SQL measures the designed behaviour correctly. It is not a discovery about real hospitals.

Finding type is assigned to the principal interpretation of each BQ. Individual observations within a BQ may still have an assumption-driven component or caveat. Where this occurs, the relevant assumption is explicitly identified in the interpretation or limitation. For example, BQ-04 is principally Emergent, while Emergency Medicine's higher repeat rate has a documented A-03 mechanical component.

---

## Patient Analytics

### BQ-01 Unique patients by month, facility, visit type
- **Result:** Unique patients rose from 4,184 (FY2023-24) to 7,707 (FY2024-25), and visits from 16,954 to 26,760 (+57.8%). Monthly unique patients climbed from 305 (Apr 2023) to about 1,800–2,000 per month in late FY2024-25.
- **Interpretation:** Volume builds steadily as the registered patient base accumulates.
- **Type:** Assumption-driven (A-01 uniform registration over the window; A-05 repeat-visit cadence).
- **Implication:** The early-period ramp must be considered before comparing any two periods.
- **Limitation:** A patient seen as both OP and IP in a month appears in both rows.
- **Interview:** "COUNT DISTINCT patient_id grouped by month, facility and visit type, plus an FY summary."

### BQ-02 Age and gender distribution
- **Result:** Age at first visit: 0–17 = 17.3%, 18–29 = 20.7%, 30–44 = 17.6%, 45–59 = 15.8%, 60–74 = 14.9%, 75+ = 13.7%. Female 4,426, male 4,182, other 92. Department profiles follow the eligibility rules (Paediatrics under 18; O&G female 18–50).
- **Type:** Assumption-driven (A-02 demographic mix and structural eligibility rules).
- **Implication:** Demographic splits validate generator rules rather than reveal market patterns.
- **Limitation:** Age is measured at first visit, so a patient appears once per department.
- **Interview:** "CASE WHEN builds age bands from AGE(first_visit, DOB); COUNT FILTER splits by gender."

### BQ-03 New vs returning patients by month
- **Result:** Returning share rose from 0% (Apr 2023) to 74.4% (Mar 2024) and 81–82% (Jan–Mar 2025). New patients stayed roughly flat at 318–417 per month.
- **Interpretation:** Retention looks like it rises, but most of the rise is **left-censoring**: no history exists before 1 Apr 2023.
- **Type:** Assumption-driven (A-01, A-05; left-censoring).
- **Implication:** Use FY2024-25 for any retention comparison.
- **Limitation:** Early "new" counts include patients whose true history predates the dataset.
- **Interview:** "A CTE finds each patient's first visit; a patient is new in the month of that first visit and returning in any later month."

### BQ-04 Repeat patient rate by department (FY2024-25)
- **Result:** Network repeat rate 41.4% (3,191 of 7,707). Departments range from 37.6% (Radiology & Imaging) and 37.7% (Paediatrics) to 52.1% (O&G) and 58.1% (Emergency Medicine).
- **Interpretation:** No department-level repeat target exists in the generator, so the spread is emergent. Emergency Medicine's top rate is partly mechanical: ER patients are drawn from the already-registered pool (A-03 selection rule), which favours established patients.
- **Type:** Emergent (with the ER caveat).
- **Implication:** In a real setting, a high ER repeat rate would prompt a review of follow-up care; here it is a generator artefact.
- **Limitation:** "Returning" means any earlier visit in any department.
- **Interview:** "Patients per department in FY2024-25; returning if their first-ever visit was before 1 April 2024."

### BQ-05 Interval between visits
- **Result:** 33,594 return intervals across 7,215 patients. Median 32 days, mean 53.6 days, interquartile range 13–70 days.
- **Interpretation:** Mean is well above median, so the gap distribution is right-skewed.
- **Type:** Assumption-driven (A-05 exponential gaps, mean 52 days).
- **Implication:** The median is the right summary metric for return cadence.
- **Limitation:** Same-day encounters are collapsed into one visit date.
- **Interview:** "LAG gives the previous visit date per patient; PERCENTILE_CONT(0.5) gives the median, because the mean is skewed."

### BQ-06 Revenue by patient spend decile
- **Result:** Top decile (870 patients) = 51.2% of net revenue; top two deciles = 74.4%; bottom five deciles = 3.4%.
- **Interpretation:** Revenue is highly concentrated in a minority of patients. High-value inpatient activity accounts for a substantial share of the revenue generated by the highest-spend patient segment in this synthetic dataset. No concentration target was set in the generator.
- **Type:** Emergent.
- **Implication:** Analytical segmentation only. Revenue exposure is concentrated in a small high-spend segment.
- **Limitation:** This is not a clinical or value judgement about patients and not an Apollo customer segment.
- **Interview:** "Sum net revenue per patient, NTILE(10) by spend, then each decile's share of the total."

## Department Analytics

### BQ-07 Department rankings
- **Result:**
  - By net revenue: Orthopaedics #1 (₹231.6M), Neurosurgery #2 (₹211.1M), General Surgery #3.
  - By visits: Nephrology #1 (4,850), Radiology #2.
  - By revenue per visit: O&G #1 (₹103.4k), Neurosurgery #2 (₹102.7k).
  - Emergency Medicine ranks last on revenue and revenue per visit (₹4.6k).
- **Interpretation:** High-volume departments are not the high-revenue departments.
- **Type:** Emergent (specific ranks are not set; they arise from randomly perturbed demand weights, LOS and price ranges).
- **Implication:** Volume-based and revenue-based department priorities differ.
- **Limitation:** Ranks reflect synthetic tariffs.
- **Interview:** "Aggregate visits and revenue per department, then RANK on each metric."

### BQ-08 Department revenue share, FY2023-24 vs FY2024-25
- **Result:**
  - Largest gains: Cardiothoracic Surgery +1.68 pp, Radiology +1.26 pp, O&G +1.24 pp.
  - Largest losses: Orthopaedics −3.26 pp (revenue −10.8%), Neurosurgery −1.84 pp.
- **Interpretation:** The generator has no department growth parameter, so these mix shifts come from random variation in stays and procedures.
- **Type:** Emergent.
- **Implication:** Year-on-year mix shifts of 1–3 pp can occur without any underlying cause, so they should not be over-read.
- **Limitation:** Only two FYs are available.
- **Interview:** "SUM with FILTER for each FY, then share = department revenue ÷ SUM() OVER () of that FY."

### BQ-09 OP vs IP revenue split
- **Result:** IP = 85.5% of net revenue from 16.1% of visits. OP = 8.3% of revenue from 73.7% of visits. Day-care 5.3%, ER 0.9%. By department, IP share ranges from 73.9% (Neurology) to 98.2% (Neurosurgery); Radiology is 100% OP.
- **Type:** Assumption-driven (A-07 IP procedure incidence, A-08 surgical price ranges, A-11 room charges).
- **Implication:** Within this model, inpatient capacity is the main revenue lever.
- **Limitation:** Tariff structure is synthetic.
- **Interview:** "SUM(net_amount) FILTER by visit_type per department, divided by the department total."

### BQ-10 Project-defined 30-day OP→IP conversion
- **Result:** Network 31.2% (2,424 of 7,767 OP patients, qualifying OP 1 Apr 2023 – 1 Mar 2025). O&G 48.4%, General Surgery 30.2%, Neurosurgery 28.2%, … Radiology 9.6%.
- **Interpretation:** Surgical departments convert most, as the generator's referral preference specifies (surgical 50% vs medical 30%).
- **Type:** Assumption-driven (A-21).
- **Implication:** The method correctly recovers the designed referral pathway.
- **Methodology note:** Department-level conversion rates are calculated independently by qualifying OP department, so a patient may contribute to more than one department denominator if they have qualifying OP visits in multiple departments. The network rate uses distinct patients across the network.
- **Limitation:** This is a project-defined methodology, not Apollo's. Right-censoring is applied after 1 Mar 2025. `12_kpi_validation.sql` (K18) applies the same definition to FY2024-25 qualifying OP visits only, so its value differs by scope.
- **Interview:** "LEFT JOIN each qualifying OP visit to IP admissions 0–30 days later, flag converted patients, and divide by OP patients."

## Doctor Analytics

### BQ-11 Top 3 doctors by revenue per department
- **Result:** A Facility A (Mumbai) doctor ranks #1 in 9 of 14 departments. Example: Neurosurgery #1 at ₹84.3M.
- **Interpretation:** Facility A has the most operating beds (18), so it holds the most IP stays, and its doctors accumulate more inpatient revenue.
- **Type:** Assumption-driven (A-06 productivity weights; A-18 bed allocation).
- **Implication:** Doctor rankings can mostly reflect facility capacity, so rankings should be normalised before judging performance.
- **Limitation:** Doctor names and productivity are synthetic.
- **Interview:** "Doctor revenue CTE, then RANK() OVER (PARTITION BY department ORDER BY revenue DESC), keep rank ≤ 3."

### BQ-12 Doctors above their department average
- **Result:** 38 of 72 doctors are above their department's average doctor revenue. Example: the top Cardiology doctor is 29.8% above average.
- **Type:** Assumption-driven (A-06).
- **Implication:** Above-average status is roughly half the roster, as expected when departments have a few high earners.
- **Limitation:** Small departments (3–4 doctors) have unstable averages.
- **Interview:** "One CTE for doctor revenue, one for the department average, JOIN them and filter."

### BQ-13 Average monthly visit load per doctor
- **Result:** Highest: Nephrology 40.4 visits per doctor per active month and Gastroenterology 39.7. Lowest: O&G 12.6 and Cardiothoracic Surgery 16.6.
- **Type:** Assumption-driven (A-04 demand weights, A-06, roster size).
- **Implication:** Medical departments show higher throughput per doctor than surgical ones in this model.
- **Limitation:** Appointment-slot capacity is not modelled; the load figures assume no booking ceiling.
- **Interview:** "Visits per doctor ÷ months active since joining (so mid-window joiners are not penalised), averaged per department."

### BQ-14 Top doctor's share of department revenue
- **Result:** Ranges from 19.4% (Emergency Medicine, 8 doctors) to 39.9% (Neurosurgery, 3 doctors). Every department is above its equal-share benchmark.
- **Type:** Assumption-driven (A-06 lognormal weights; A-18; roster size).
- **Implication:** Departments with 3–4 doctors show higher top-doctor revenue concentration in this dataset, which could represent concentration risk in a real operating environment.
- **Limitation:** Concentration is partly mechanical in small departments.
- **Interview:** "ROW_NUMBER picks the top doctor per department; their revenue ÷ department revenue, compared with 1/N."

### BQ-15 No-show rate by doctor
- **Result:** 64 doctors with ≥ 100 bookings (Emergency doctors have no appointments). Rates range 7.3%–15.6%, average 11.7%, network 11.8%.
- **Interpretation:** No-show status was generated independently of doctor, so this spread is sampling variation.
- **Type:** Assumption-driven (A-16, D-02).
- **Implication:** Doctor-level differences of this size should not be treated as performance signals without a statistical test.
- **Limitation:** Descriptive only; doctors do not cause no-shows in this data.
- **Interview:** "COUNT FILTER no-shows ÷ COUNT bookings per doctor, HAVING at least 100 bookings."

## Procedure Analytics

### BQ-16 Procedure volume and revenue
- **Result:**
  - Highest volume: IV Fluid and Infusion Therapy (933 units), Nebulisation Therapy (891), CT Abdomen (819).
  - Highest revenue: Craniotomy (₹75.0M), Total Knee Replacement (₹59.7M), Pacemaker Implantation (₹54.5M).
  - Major Surgery = 70.9% of procedure revenue from 15.8% of units; Diagnostic = 37.5% of units but 5.4% of revenue.
- **Type:** Assumption-driven (A-07 frequency, A-08 price ranges).
- **Implication:** Volume leaders and revenue leaders are different procedures.
- **Limitation:** Procedure revenue is gross line-level `charged_amount`, before bill-level discounts.
- **Interview:** "SUM(quantity) and SUM(charged_amount) per procedure from visit_procedures, then RANK on each."

### BQ-17 Procedure contribution to procedure revenue
- **Result:** The top 12 of 57 procedures generate 64.6% of procedure revenue; the top 20 generate 86.1%. Procedure charges are 58.4% of gross billed amount.
- **Methodology note:** No visit-level bill amount is allocated to procedures. Each line carries its own charge, which reconciles to `billing.procedure_charges` (validated).
- **Type:** Assumption-driven (A-08).
- **Implication:** A short list of surgical procedures dominates procedure income.
- **Limitation:** Gross basis. Net procedure revenue cannot be derived without allocating bill discounts, so no allocation is invented.
- **Interview:** "Each procedure's charges ÷ total; a running SUM gives the cumulative share for a Pareto view."

### BQ-18 Monthly procedure volume and MoM
- **Result:** Monthly units rose from 529 (Apr 2023) to 943 (Mar 2025). MoM change ranged from −11.2% (Sep 2024) to +20.4% (Oct 2023).
- **Type:** Assumption-driven (patient-base ramp A-01/A-05; A-07).
- **Implication:** Month-to-month swings of ±10–20% are normal noise at this volume.
- **Limitation:** No seasonality was designed.
- **Interview:** "GROUP BY month, then LAG(units) for the previous month and percentage change."

### BQ-19 Procedures associated with IP admissions
- **Result:**
  - All 57 procedures meet the ≥ 30-unit threshold.
  - 20 procedures are 100% inpatient, e.g. Neonatal Phototherapy, Caesarean Section, Craniotomy, CABG.
  - Among multi-setting procedures, the highest IP shares are Chemotherapy Cycle 84.0%, Haemodialysis 81.1% and Nebulisation Therapy 80.0%.
- **Interpretation:** Care-setting eligibility is a generator configuration, so 100% shares are by construction.
- **Type:** Assumption-driven (A-07 care-setting flags).
- **Implication:** Useful as a check that procedure–setting rules are respected.
- **Limitation:** Descriptive association; no clinical causation implied.
- **Interview:** "IP units ÷ all units per procedure using FILTER, with HAVING to drop low-volume procedures."

## Revenue Analytics

### BQ-20 Monthly and quarterly net revenue and growth
- **Result:**
  - FY net revenue grew 9.9% (₹709.0M → ₹779.5M) while visits grew 57.8%.
  - Average net revenue per bill fell from ₹41.9k to ₹29.1k.
  - Quarterly YoY growth: Q1 +19.8%, Q2 +11.6%, Q3 +2.2%, Q4 +7.5%.
  - Monthly MoM ranged from −17.7% (Sep 2023) to +27.6% (May 2023).
- **Interpretation:** Revenue grew much less than visits, a pattern consistent with the fixed-bed inpatient capacity and the synthetic pricing structure, while OP volume continued to grow with the patient base. The SQL describes this pattern; it does not establish causality.
- **Type:** Assumption-driven (A-01/A-05 volume ramp; A-08 FY2 tariff uplift; A-18 fixed capacity). The falling average bill is consistent with the interaction between the capacity-bound inpatient component and growth in lower-value OP activity; no parameter targets it directly.
- **Implication:** Visit growth overstates financial growth when capacity-bound IP dominates revenue.
- **Limitation:** Early YoY figures are inflated by the April 2023 ramp.
- **Interview:** "GROUP BY month and FY quarter, LAG(1) for MoM/QoQ, LAG(12) and LAG(4) for YoY."

### BQ-21 Charge component mix (gross)
- **Result:** Procedures 58.4%, room 20.2%, diagnostics 8.6%, pharmacy 8.4%, consultation 4.5%. Mix differs by visit type: IP is procedure- and room-led; ER is diagnostics-led (42.7%); OP consultation is 23.3%.
- **Type:** Assumption-driven (A-08, A-10, A-11, A-12).
- **Implication:** Procedure and room tariffs drive the gross bill.
- **Limitation:** Components are pre-discount.
- **Interview:** "SUM each component ÷ SUM(gross_amount), overall and by visit type."

### BQ-22 Revenue and average bill by payer
- **Result:**
  - Self-pay: 64.4% of bills, 38.8% of net revenue, average bill ₹20.5k.
  - Insurance-TPA: 18.2% of bills, 38.2% of revenue, average ₹71.5k.
  - Govt scheme: 12.3% of revenue. Corporate: 10.7%.
- **Type:** Assumption-driven (A-13 payer mix by visit type; IP is more often insured).
- **Implication:** Institutional payers carry most of the high-value inpatient revenue.
- **Limitation:** Payer shares are generator parameters.
- **Interview:** "GROUP BY payer_type with revenue share and AVG(net_amount)."

### BQ-23 Discount rate by department and payer
- **Result:** Corporate 7.52%, Self-pay 0.24%, Insurance-TPA and Govt scheme 0%. Department rates are narrow, 0.74%–1.18%, reflecting each department's corporate payer share.
- **Type:** Assumption-driven (A-14 discount rule by payer).
- **Implication:** Discounts are a corporate-contract effect, not a department effect.
- **Limitation:** Discount policy is a simulation rule.
- **Interview:** "SUM(discount) ÷ NULLIF(SUM(gross), 0) by department and payer: a ratio of sums, not an average of ratios."

### BQ-24 Collections and outstanding by payer
- **Result:**
  - Collection rates: Self-pay 98.3%, Insurance-TPA 91.7%, Corporate 91.6%, Govt scheme 83.2%.
  - Total collected ₹1,387.1M; outstanding ₹101.4M.
  - By billing-quarter cohort, rates are 97.7%–98.5% for every cohort up to FY2024-25 Q3, then drop to 61.1% for FY2024-25 Q4 (Corporate 36.6%, Govt 16.5%).
- **Interpretation:** The Q4 drop is **right-censoring**: institutional payers settle after a lag that runs past the 31 Mar 2025 cutoff. It is not a performance decline.
- **Type:** Assumption-driven (A-15 settlement lags and deductions).
- **Implication:** Collection KPIs must be read by cohort with settlement-time context. Govt-scheme deductions are the main structural leakage.
- **Limitation:** Only Success payments count; failed attempts are excluded.
- **Interview:** "Aggregate successful payments per bill first, then LEFT JOIN to billing so net revenue isn't multiplied by the payment count."

## Operational Analytics

### BQ-25 Cancellation and no-show rates
- **Result:**
  - Completed 76.5%, Cancelled 11.7%, No-show 11.8%.
  - Monthly ranges: cancellation 9.1%–14.0%, no-show 10.6%–14.2%.
  - By department, no-show ranges 10.5% (Paediatrics) to 12.7% (Cardiology, Orthopaedics).
  - The "Unknown" channel (uncaptured, DQ-06) has the highest no-show rate (13.5%) on a small base of 1,275 bookings.
- **Type:** Assumption-driven (A-16, D-02 independent base rates).
- **Implication:** About 1 in 4 booked slots does not become a visit, which is the main appointment-leakage figure.
- **Limitation:** Variation across dimensions is sampling noise by design.
- **Interview:** "COUNT FILTER by status ÷ COUNT, grouped by month, department and channel."

### BQ-26 No-show rate by lead-time bucket
- **Result:** Same day 12.2%, 1–3 days 12.0%, 4–7 days 11.6%, 8–14 days 11.2%, 15+ days 11.8%. There is no monotonic pattern; the spread is 1.0 pp.
- **Interpretation:** This is consistent with the generator, which applies no lead-time effect.
- **Type:** Assumption-driven (A-17, D-02).
- **Implication:** The method is ready; in real data a widening gap would justify reminder policies.
- **Limitation:** Descriptive association only; nothing causal.
- **Interview:** "Lead days = scheduled date − booking date, bucketed with CASE, then no-show share per bucket."

### BQ-27 Average length of stay
- **Result:** ALOS 4.83 days (FY2023-24) and 5.05 days (FY2024-25); 107 and 105 same-day stays respectively. Surgical departments are highest (General Surgery 6.78, O&G 6.73, Neurosurgery 6.69); Neurology is lowest (2.94). Facilities range 4.78–5.10.
- **Type:** Assumption-driven (A-19 LOS bands: surgical 4.5–8.5, medical 3.5–6.5).
- **Implication:** Surgical case mix drives bed-day consumption.
- **Limitation:** Same-day stays count as 1 patient-day (project convention).
- **Interview:** "SUM(GREATEST(discharge − admission, 1)) ÷ number of discharges, attributed to the discharge period."

### BQ-28 Occupancy and project-defined ARPOB
- **Occupancy result:** All facility-FYs fall within 67.4%–71.2%. Metro 68.8% / 68.7%; Non-metro 69.6% / 70.0%. No facility-day exceeds capacity (validated).
- **Project-defined ARPOB result:** Metro ₹39.6k (FY2023-24) / ₹40.3k (FY2024-25); Non-metro ₹28.1k / ₹29.3k. Highest facility: Simulated Hospital C, ₹41.9k in FY2024-25.
- **Interpretation:** Occupancy is set by the uniform bed-turnover gap. The tier ARPOB gap follows tier room rates and fees.
- **Type:** Assumption-driven (A-18, A-19, A-10, A-11).
- **Implication:** Within the model, revenue yield per bed-day differs by tier pricing, not by utilisation.
- **Limitation:**
  - Bed capacity is a synthetic simulation parameter calibrated for analytical coherence with the generated dataset volume. It does not represent actual Apollo Hospitals facility capacity.
  - Project-defined ARPOB implementation = IP net revenue ÷ IP patient-days (discharge-period attribution). It is not Apollo's methodology; Apollo historically reported ARPOB on a different basis and discontinued it from Q1 FY26.
- **Interview:** "Patient-days inside each FY ÷ (beds × days) for occupancy. For ARPOB, IP revenue ÷ patient-days of the same stays discharged in the FY."

## Trend Analytics

### BQ-29 Cumulative FY revenue vs prior FY
- **Result:** FY2024-25 year-to-date revenue was 33.5% ahead of FY2023-24 after April. The lead narrowed steadily to 9.9% by March (₹779.5M vs ₹709.0M).
- **Interpretation:** The large early lead reflects FY2023-24's ramp-up start, not acceleration.
- **Type:** Assumption-driven (A-01/A-05 ramp; A-08 uplift).
- **Implication:** Year-to-date comparisons against a ramp-up year flatter early months.
- **Limitation:** Only two FYs.
- **Interview:** "Running SUM() OVER (PARTITION BY FY ORDER BY FY month), then the two FYs joined on month number."

### BQ-30 Peak and trough months
- **Result:**
  - Visits: Apr, May and Jun rank bottom-3 in both FYs; Jan and Mar rank top-3 in both.
  - Revenue: peaks Oct 2023 and May 2024; troughs Apr 2023 and Feb 2025.
- **Interpretation:** The repeated monthly pattern is not sufficient evidence of seasonality. In this synthetic dataset it is consistent with the designed patient-base ramp (A-01, A-05), the generator has no designed seasonality (A-20), and only two fiscal years are available.
- **Type:** Assumption-driven (A-01, A-05, A-20).
- **Implication:** Apparent seasonality should be checked against structural growth before acting on it.
- **Limitation:** Descriptive only.
- **Interview:** "RANK months within each FY by visits and revenue; flag top and bottom three; check whether the same months repeat across both years."

---

# Key Business Takeaways

**Patient Analytics**
- Revenue is highly concentrated: the top 10% of patients generate 51% of net revenue (BQ-06, emergent), with high-value inpatient activity accounting for a substantial share of that segment.
- Retention metrics need censoring discipline. Apparent rising retention is mostly a data-start artefact (BQ-03); FY2024-25 shows a 41% repeat rate (BQ-04).

**Department Analytics**
- Volume and value diverge. Nephrology and Radiology lead visits, while Orthopaedics and Neurosurgery lead revenue (BQ-07, emergent).
- Year-on-year department mix shifts of 1–3 pp can arise from noise alone (BQ-08, emergent).

**Doctor Analytics**
- Doctor rankings largely track facility bed capacity and generator productivity weights (BQ-11, BQ-14). Normalise for capacity before comparing doctors.

**Procedure Analytics**
- A few surgical procedures dominate: 12 procedures make up 65% of procedure revenue (BQ-17). Diagnostics are high-volume, low-value (BQ-16).

**Revenue Analytics**
- Visits grew 58% but net revenue grew 10%, a pattern consistent with capacity-bound IP generating 85% of revenue (BQ-09, BQ-20).
- Collections look weak in the latest quarter only because of right-censoring. Settled cohorts collect about 98% (BQ-24).

**Operational Analytics**
- Roughly 1 in 4 booked appointments did not result in a completed appointment in the synthetic dataset, including cancellations and no-shows (BQ-25).
- In this dataset lead time shows no association with no-shows (BQ-26), consistent with the generator design.
- Occupancy sits around 67–71% across facilities, while ARPOB differs by tier pricing (BQ-28).

**Trend Analytics**
- Within-year growth patterns must be separated from seasonality (BQ-30). Year-to-date comparisons against a ramp-up year overstate early growth (BQ-29).

---

## What This Project Demonstrates

- Relational analysis across 10 linked tables, using multi-table INNER and LEFT JOINs.
- Grain control:
  - aggregating payments per bill before joining;
  - procedure revenue kept at line level;
  - one bill per visit.
- Aggregation and KPI development: COUNT DISTINCT, conditional aggregation with FILTER, ratio-of-sums rates, NULLIF-safe division.
- Window functions used where the question needs them: RANK, ROW_NUMBER, LAG, running SUM, NTILE, PERCENTILE_CONT.
- Indian FY and quarter logic, with explicit boundary tests on 1 Apr 2023, 31 Mar 2024, 1 Apr 2024 and 31 Mar 2025.
- Healthcare KPIs: new/returning patients, repeat rate, OP→IP conversion, ALOS, occupancy, project-defined ARPOB, cancellation/no-show, collection rate.
- Validation and reconciliation: 33 analytics checks (29 named checks + 4 FY boundary tests; reported PASS) on top of the validation, reconciliation and KPI-validation suites.
- Interpretation discipline: separating emergent from assumption-driven findings, censoring awareness, and avoiding causal claims from descriptive data.

**Tools:** PostgreSQL (version of original execution not independently confirmed; user-reported environment: 18.6) and SQL only. No Python, BI or spreadsheet tools.

## Limitations

- Synthetic data in a scaled-down 5-facility network with synthetic bed capacity.
- Left-censoring of patient history; right-censoring for OP→IP after 1 Mar 2025 and for late-window collections.
- Only two FYs, and no designed seasonality.
- No appointment-slot capacity model.
- All results are descriptive, not causal.
- Most patterns are assumption-driven by construction.

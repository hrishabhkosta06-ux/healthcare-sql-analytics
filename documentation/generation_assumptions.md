# Synthetic Data Generation — Assumptions, Echo-Risk & Validation Record

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL
**Status:** Final (executed and validated). Pipeline entry point: `sql/run_all.sql`, run from the repository root.

**Project status:** Independent portfolio project. The dataset is 100% synthetic and was generated entirely in PostgreSQL. It is not Apollo data and does not approximate Apollo's actual performance. No parameter is calibrated to any Apollo figure.

> Bed capacity is a synthetic simulation parameter calibrated for analytical coherence with the generated dataset volume. It does not represent actual Apollo Hospitals facility capacity.

---

## 1. Technology

Generation, cleaning, validation, reconciliation and KPI checks all use PostgreSQL / SQL only (developed on PostgreSQL 16; target 14+). No Python, spreadsheet or BI tool is part of the workflow.

| Schema | Contents |
|---|---|
| `gen` | Deterministic random functions and read-only parameter views. No data tables. |
| `raw` | The 10 core tables as generated, including documented non-key data-quality issues. |
| `processed` | The 10 core tables after SQL cleaning, with full CHECK constraints. Analytics read only from here. |

Staging uses `TEMP` tables inside each script. The duplicate-merge map is a view (`processed.v_patient_merge_map`). No permanent helper table exists.

## 2. Reproducibility

- Every random value is `md5(seed | draw-key)`, converted to a uniform number in [0,1). Functions: `gen.u`, `gen.ri`, `gen.ur`, `gen.expo`, `gen.normal`.
- Because each draw is keyed by *what* is drawn, the result does not depend on query plan, join order or parallel workers. `random()` / `setseed()` were deliberately not used, since their output depends on call order.
- The seed is set per session with `SET apollo.seed = '20250331';` (also the default).
- Every `ROW_NUMBER()` used for IDs has a unique tie-breaker.
- **Verified:** two full runs in two separate databases produced identical md5 fingerprints for all six transactional tables.
- **Limitation:** guaranteed on the same PostgreSQL major version and platform. Floating-point `ln`/`exp`/`cos` could differ in the last bits on another platform and flip a rare boundary draw. The fingerprint in `sql/run_all.sql` detects this.

## 3. Generation order (FK dependency order)

| Script | Generates | Key technique |
|---|---|---|
| 01 | Schemas, functions, `gen.v_params`, 20 tables (10 raw + 10 processed) | DDL, CHECK, UNIQUE, FK, indexes |
| 02 | facilities, departments, procedures, doctors; parameter views | `VALUES`, `CROSS JOIN`, hash-ranked selection |
| 03 | patients (provisional anchor = planned first contact) | `generate_series`, inverse-CDF, `LATERAL` |
| 04 | appointments; DQ-04/05/06 | per-patient `generate_series`, running `SUM() OVER`, exponential-race weighted picks |
| 05 | visits (IP bed timelines, OP, ER, Day-care); registration finalised; DQ-07, DQ-01/02/08 | window sums, PL/pgSQL round loop of set-based `UPDATE`s, anti-joins |
| 06 | visit_procedures | `ROW_NUMBER()` random ranking within department and care setting |
| 07 | billing (1 per visit) | correlated sums, `CASE` payer mix |
| 08 | payments (Success/Failed); DQ-03 | instalments, settlement lags, censoring at cutoff |

### Key mechanisms

- **Bed-timeline IP generation.** Each operating bed is a timeline, with `next_admission = admission + patient_days + idle_gap`. Daily census therefore never exceeds beds (by construction), so capacity adjustments = 0 and nothing is silently shifted.
- **IP patient assignment.** Six rounds assign patients subject to these rules:
  - age/sex eligibility;
  - anchor on or before admission;
  - no Completed OP appointment strictly inside the stay (IC-01);
  - no overlap with the patient's other stays.

  Same-round collisions keep the earliest admission. Unassignable slots are dropped and counted.
- **Non-IP visits strictly inside a stay** are dropped and counted (IC-01). The script asserts that no appointment-linked OP visit is ever affected.
- **Registration = first contact.** After all events exist, `registration_date` is reset to the earliest booking date or visit date. Candidates with no contact are removed.

## 4. Parameters — portfolio simulation assumptions (not Apollo facts)

"Drawn" means the value comes from the seeded hash; it was not hand-chosen.

| ID | Area | Parameter |
|---|---|---|
| A-01 | Patients | 9,600 candidates; anchor uniform over the window; no-contact candidates removed |
| A-02 | Demographics | 18% minors (0–17); adults 18–90, skewed younger; sex 49% M / 50% F / 1% Other |
| A-03 | Visit mix | OP from Completed appointments + 1,000 walk-in candidates; ER 1,800 candidates + ER visit on admission day for 15% of IP stays; Day-care 1,600 candidates |
| A-04 | Department demand | Category base (Medical 1.0, Surgical 0.8, Diagnostic 0.6) × drawn ±20%. 14 departments; Non-metro facilities offer 9 |
| A-05 | Appointment frequency | Count per patient ~ exponential (mean 8.3, cap 25); gaps ~ exponential (mean 52 days); Sunday → Monday |
| A-06 | Doctor workload | Lognormal productivity weight exp(0.35·Z), drawn. One founding doctor per facility–department + 12 extra doctors on hash-ranked combinations (half join inside the window) |
| A-07 | Procedure frequency | IP 0/1/2 = 10/70/20%; Day-care 1/2 = 75/25%; OP Radiology 90%, other OP 12%; ER 30%. Procedure choice is equal-weight random within department and care setting |
| A-08 | Pricing | Catalogue ranges by procedure (INR, judgement-based, not sourced tariffs); price × U(0.95, 1.05); FY2024-25 tariff uplift drawn once in [3%, 6%] |
| A-10 | Consultation | Base 600/1,000/1,500 by designation × U(0.85, 1.15) × 0.8 for Non-metro; ER fee 1,200 Metro / 900 Non-metro; IP = fee × patient-days |
| A-11 | Room | Metro ₹6,000–12,000, Non-metro ₹3,000–6,000 per day (drawn per facility) |
| A-12 | Pharmacy / diagnostics | IP scaled by patient-days; OP/ER/Day-care probabilistic (see `07_generate_billing.sql`) |
| A-13 | Payer mix | OP 72/12/10/6; ER 60/25/8/7; Day-care 45/35/10/10; IP 35/40/12/13 (Self-pay / Insurance-TPA / Corporate / Govt scheme) |
| A-14 | Discounts | Corporate U(5%, 10%); 5% of Self-pay bills get 5%; others 0 |
| A-15 | Collections | Self-pay immediate (3% partial; IP self-pay in 2 instalments, 3% unpaid remainder); Insurance 15–75 day lag, 70% full / 30% with deductions; Corporate 30–90 days, full; Govt 30–120 days, 50% full. Settlements after 2025-03-31 are not recorded |
| A-16 | Cancel / no-show | Independent base rates: Completed 76%, Cancelled 12%, No-show 12% (D-02) |
| A-17 | Lead time / channel | Same-day 15%, 1–3 d 35%, 4–7 d 25%, 8–14 d 15%, 15–60 d 10%; booking floored at 2023-04-01 (D-04). Channel: Phone 35 / Website 20 / Mobile App 30 / Front Desk 15 |
| A-18 | Capacity | **Fixed** beds 18 / 15 / 15 / 10 / 11 = 69. Idle gap between stays ~ exponential, mean 2.6 days, identical for every facility |
| A-19 | LOS | Department mean drawn: Surgical U(4.5, 8.5), Medical U(3.5, 6.5); LOS = 1 + exponential; 3% same-day; cap 30 |
| A-20 | Seasonality | None designed. Monthly variation comes only from random dates |
| A-21 | OP→IP pathway | ER-origin 15% of stays; of the rest, 50% (Surgical) / 30% (Medical) prefer a patient with a Completed OP visit in the same facility + department 0–30 days earlier |
| A-22 | DQ incidence | See §6 |

Bed counts and volume parameters were fixed after a multi-seed test, before any analytical result was produced. With drawn bed counts, some seeds exceeded the target row-count ranges.

## Design decision codes used in SQL comments

| Code | Meaning |
|---|---|
| D-01 | Scaled-down synthetic bed capacity (69 beds) |
| D-02 | Cancellation and no-show generated independently of every other variable |
| D-03 | Synthetic facility names (`Simulated Hospital X (City)`) |
| D-04 | Bookings never earlier than 1 Apr 2023 |
| D-05 | Discharge status excludes `Deceased` |
| CR-01 | ARPOB is project-defined (not Apollo's methodology) |
| CR-02 | `payments.payment_status` (Success / Failed); only Success counts as collected |
| CR-03 | Findings tagged Emergent or Assumption-driven |
| IC-01 | No OP / ER / Day-care visit strictly between a patient's admission and discharge dates |

## 5. Echo-risk register (supports CR-03 `finding_type`)

A finding is **Assumption-driven** when it can be materially explained by a row below. Otherwise it is classified **Emergent**. The tag is assigned only after the analytical query has been run.

| Result area | Explicitly parameterised (echo risk) | Expected to emerge |
|---|---|---|
| No-show / cancellation (BQ-15, 25, 26) | Overall base rates only (A-16) | Any pattern by doctor, department, facility, channel or lead time. The generator encodes none, so an observed difference is most likely sampling variation |
| Doctor performance (BQ-11–14) | Productivity weights are random (A-06) | Rankings, concentration |
| Department differences (BQ-07–10) | Category base weights, LOS bands, price ranges (A-04, A-08, A-19) | Specific department ranks and contributions |
| Payer behaviour (BQ-22–24) | Payer mix, discount rule, settlement lags (A-13–A-15) — **strong echo** | Interactions with department or facility |
| Revenue trend (BQ-20, 29) | FY2 tariff uplift (A-08); no volume growth parameter | Month-to-month movement |
| Seasonality (BQ-18, 30) | None (A-20) | Any peak or trough is random variation |
| Procedure utilisation (BQ-16–19) | Procedure count probabilities, price ranges, care-setting flags (A-07, A-08) | Individual procedure ranks |
| Repeat behaviour (BQ-03–05) | Appointment count / gap distributions, uniform anchors (A-01, A-05); left-censoring | Department-level repeat rates |
| Occupancy / ALOS / ARPOB (BQ-27, 28) | Beds, idle gap, LOS bands (A-18, A-19) — **strong echo** | Facility-level differences (from department mix and LOS) |
| OP→IP (BQ-10) | Referral preference shares (A-21) — **strong echo** | Department-level spread within the band |
| Revenue concentration (BQ-06) | Price ranges and visit frequency | Decile shares |

## 6. Data-quality register (raw only)

| ID | Issue | Where | Injected rate | Detection (09) | Cleaning (10) |
|---|---|---|---|---|---|
| DQ-01 | City casing | patients.city | 4% | `city <> initcap(lower(btrim(city)))` | `initcap(lower(btrim()))` |
| DQ-02 | Leading/trailing spaces | patients.patient_name (3%), city (2%) | — | value ≠ `btrim(value)` | `btrim` + collapse internal spaces |
| DQ-03 | Payer label variants | billing.payer_type | 4% | outside canonical set | normalised-text mapping |
| DQ-04 | Channel label variants | appointments.booking_channel | 4% | outside canonical set | mapping |
| DQ-05 | NULL cancellation reason | Cancelled appointments | 10% | Cancelled AND NULL | `'Not recorded'` |
| DQ-06 | NULL booking channel | appointments | 3% | IS NULL | `'Unknown'` |
| DQ-07 | Duplicate-like patients | patients + child rows | 2% of patients with ≥4 events | same normalised name + DOB + gender + city | survivor = earliest registration; remap appointments and visits |
| DQ-08 | Gender label variants | patients.gender | 3% | outside canonical set | mapping |

Keys, foreign keys, dates and amounts are never corrupted. The raw data always loads.

## 7. Index rationale (processed)

PostgreSQL does not index foreign keys automatically. Indexes were created only where the BQ joins and filters need them:

| Index | Reason |
|---|---|
| `appointments(patient_id)`, `appointments(doctor_id)` | Patient history and doctor no-show joins |
| `appointments(scheduled_datetime)` | Monthly and lead-time filtering |
| `visits(patient_id, visit_date)` | New/returning, return intervals, OP→IP window lookups |
| `visits(doctor_id)`, `visits(department_id)` | Doctor and department aggregations |
| `visits(facility_id, visit_date)` | Facility and occupancy analysis |
| `visit_procedures(visit_id)`, `visit_procedures(procedure_id)` | Bridge joins |
| `billing(bill_date)` | Monthly, FY and running-total revenue |
| `payments(bill_id)` | Collections per bill |

Primary keys and UNIQUE constraints (`visits.appointment_id`, `billing.visit_id`) already provide their own indexes.

## 8. Validation record (executed, seed 20250331)

| Stage | Result |
|---|---|
| 09 on `raw` | 34/34 integrity checks PASS; all 8 DQ scenarios detected (D07 = exactly the 118 injected records, so no accidental identity collisions); raw.patients = 9,121 |
| 10 cleaning | 0 child rows lost; 118 duplicate-like records merged; child rows remapped; processed.patients = 9,003 |
| 09 on `processed` | **42/42 PASS** |
| 11 reconciliation | **27/27 PASS** |
| 12 KPI dual-method | **21/21 PASS** |
| Reproducibility | identical fingerprints in two separate databases |
| Robustness | seeds 20250331, 7, 1, 99, 424242 (final parameters): 0 FAIL, 124/124 PASS, all row counts inside target ranges (§8.2) |

### Row counts (processed, seed 20250331)

| Table | Rows | Locked range |
|---|---|---|
| facilities | 5 | 4–5 |
| departments | 14 | 12–15 |
| doctors | 72 | 60–80 |
| procedures | 57 | 40–60 |
| patients | 9,003 | 8,000–10,000 |
| appointments | 40,866 | 40,000–50,000 |
| visits | 43,714 (IP 7,056 ≈ 16.1%) | 35,000–45,000 |
| visit_procedures | 17,366 | 12,000–20,000 |
| billing | 43,714 | = visits |
| payments | 45,058 (≈1.03 per bill; 453 Failed) | ≈1.0–1.3 per bill |

### 8.1 Patient lineage (raw → processed), verified by SQL

| Step | Rows | Source |
|---|---|---|
| Candidates generated (03) | 9,600 | `gen.v_params.candidate_patients` |
| Removed: no contact (05 §G) | −597 | 05 diagnostics `patients_removed_no_contact` |
| Real patients | 9,003 | |
| Added: DQ-07 duplicate-like records (05 §H) | +118 | 05 diagnostics `duplicate_like_records_created` |
| **raw.patients** | **9,121** | `SELECT count(*) FROM raw.patients` |
| Merged away in cleaning (10) | −118 | `v_patient_merge_map` rows where `raw_patient_id <> survivor_id` |
| **processed.patients** | **9,003** | `SELECT count(*) FROM processed.patients` |

Every merge group holds exactly 2 records. All 118 removed records are the injected duplicates; no original record was removed.

Injected IDs are numbered from the highest *remaining* patient ID + 1, so they run **PAT09592–PAT09709**. Candidate numbers PAT09592–PAT09600 had already been removed as no-contact before injection, so they are reused. There is no collision, because those IDs never coexist.

Raw-patient figures from interim runs on earlier parameter sets are superseded; 9,121 is the only valid raw patient count for the final dataset.

### 8.2 Robustness (final parameters, processed counts)

| Seed | Patients | Appointments | Visits | Visit procedures | Payments | Checks |
|---|---|---|---|---|---|---|
| 20250331 | 9,003 | 40,866 | 43,714 | 17,366 | 45,058 | 124/124 PASS |
| 7 | 9,020 | 40,849 | 43,502 | 17,652 | 44,824 | 124/124 PASS |
| 1 | 8,984 | 41,511 | 44,413 | 17,078 | 45,787 | 124/124 PASS |
| 99 | 9,023 | 41,480 | 43,947 | 17,371 | 45,259 | 124/124 PASS |
| 424242 | 9,027 | 41,064 | 44,355 | 18,012 | 45,845 | 124/124 PASS |

124 = 34 raw integrity + 42 processed validation + 27 reconciliation + 21 KPI. The 8 raw DQ checks report `DQ_FOUND` by design and are not counted as PASS.

Generation transparency counts:
- IP capacity adjustments: 0 (by construction).
- Unassignable IP slots dropped: 11.
- Non-IP visits removed by IC-01: OP 21, ER 26, Day-care 34.
- Candidates removed for no contact: 597.

## 9. Known limitations

- **Scaled-down network.** Bed counts are small so that occupancy is meaningful at this patient volume.
- **Left-censoring.** History starts 2023-04-01, so FY2023-24 overstates "new" patients.
- **Right-censoring.** Late-window bills have had less time to settle. Lower collection rates in recent cohorts are expected and are not a performance signal.
- **Appointment slots.** Doctor slot capacity is not modelled; a doctor can have overlapping appointment times.
- **Walk-in share.** Walk-in OP is a small share of OP, because total visits had to stay within the target ceiling.

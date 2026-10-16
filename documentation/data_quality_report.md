# Data Quality Report

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

**Data:** synthetic. Seed 20250331, PostgreSQL (version of original execution not independently confirmed; user-reported environment: 18.6).

The reported counts are outputs of repository SQL scripts. `sql/run_all.sql` executes scripts 01–12; analytics scripts 13–19 and their validation blocks are run separately.

## Pipeline

```
raw (generated + documented DQ issues)
  → 09 validation on raw
  → 10 cleaning
  → 09 validation on processed
  → 11 reconciliation
  → 12 KPI validation
  → 13–19 analytics (each with its own validation block)
```

## Summary

| Stage | Script | Result |
|---|---|---|
| Raw integrity validation | `09_data_quality_validation.sql` on `raw` | **34/34 PASS**, plus 8 documented DQ scenarios detected (`DQ_FOUND`, expected) |
| Processed validation | `09_data_quality_validation.sql` on `processed` | **42/42 PASS** (DQ checks = 0) |
| Reconciliation | `11_reconciliation.sql` | **27/27 PASS** |
| KPI dual-method validation | `12_kpi_validation.sql` | **21/21 PASS** |
| Analytics validation | Validation blocks in `13`–`19` | **33/33 PASS** (29 named analytics validations + 4 fiscal-year boundary tests) |
| Reproducibility | md5 fingerprints in `run_all.sql` | Identical across runs and across separate databases |
| Robustness | Seeds 20250331, 7, 1, 99, 424242 | Each 124/124 PASS; all row counts within target ranges |

## Checks covered by the 42 validation checks (`09`)

| Area | Checks |
|---|---|
| Structural | Primary keys unique and non-null (all 10 tables); FK orphans; allowed values; IP-only fields populated only for IP; cancellation reason only on Cancelled |
| Temporal | DOB < registration; registration = first contact and inside window; booking ≤ scheduled; visit and appointment dates match; admission ≤ discharge; no open stays; no event before DOB; doctor joined before activity; procedure date within stay; bill_date rule; payment date between bill date and cutoff |
| Appointment ↔ visit | Completed → exactly one visit; Cancelled/No-show → no visit; linked visit matches patient, doctor and facility and is OP |
| Patient | Department eligibility (Paediatrics < 18; O&G female 18–50) |
| Inpatient | No overlapping stays; IC-01 (no OP/ER/Day-care visit strictly inside a stay); patient-days ≥ 1; daily census ≤ operating beds |
| Financial | gross = sum of components; net = gross − discount; procedure_charges = sum of lines; successful payments ≤ net; failed attempts paired; no non-positive amounts |
| Relationship | Exactly one bill per visit; visit/appointment facility and department match the doctor; procedure department = visit department; Day-care has a procedure; ER is in Emergency Medicine |

## Deliberate raw data-quality issues: detection → cleaning

Keys, foreign keys, dates and amounts are never corrupted, so the raw data always loads.

| ID | Issue | Detected in raw (rows) | Cleaning (`10`) | Rows changed |
|---|---|---|---|---|
| DQ-01 | City casing | 359 | `initcap(lower(btrim()))` | 790 *(DQ-01 + DQ-02 combined)* |
| DQ-02 | Leading/trailing whitespace (name, city) | 456 | `btrim` + collapse spaces | *(included above)* |
| DQ-03 | Payer label variants | 1,763 | Mapped to 4 canonical payer types | 1,763 |
| DQ-04 | Channel label variants | 1,509 | Mapped to 4 canonical channels | 2,784 *(DQ-04 + DQ-06 combined)* |
| DQ-05 | NULL cancellation reason on Cancelled | 498 | Set to `Not recorded` | 498 |
| DQ-06 | NULL booking channel | 1,275 | Set to `Unknown` | *(included above)* |
| DQ-07 | Duplicate-like patient records | 118 | Survivor = earliest registration; child rows remapped | 118 records merged; 420 appointments and 481 visits remapped |
| DQ-08 | Gender label variants | 276 | Mapped to Male / Female / Other | 272 *(4 were on merged non-survivor records)* |

Child rows lost in cleaning: **0**.

## Patient lineage (verified by SQL)

| Step | Rows |
|---|---|
| Candidates generated | 9,600 |
| No-contact candidates removed | −597 |
| Real patients | 9,003 |
| Duplicate-like records injected (DQ-07) | +118 |
| **raw.patients** | **9,121** |
| Merged in cleaning | −118 |
| **processed.patients** | **9,003** |

Of the 9,003 processed patients, 8,700 have at least one visit. The remaining 303 had only cancelled or not-attended bookings.

## Reconciliation (`11`, 27/27 PASS)

| Area | What reconciles |
|---|---|
| Visits | Total = OP + IP + ER + Day-care; bills = visits |
| Appointments | Statuses sum to total; Completed = appointment-linked OP visits |
| Patients | New + returning = total for each FY; distinct visiting patients = patients with visits |
| Billing | gross − discount = net; gross = sum of components |
| Procedures | Lines = per-procedure totals = SUM(billing.procedure_charges); quantity by department |
| Payments | No bill over-collected; net − collections = Σ outstanding; collections by payer reconcile |
| Revenue | Total = Σ department = Σ payer = Σ facility = Σ month = FY2023-24 + FY2024-25; doctor revenue = department revenue |
| Occupancy | Facility-days with census > beds = 0; stay patient-days = daily census = month-allocated patient-days |
| Contribution | Department, payer and procedure shares each sum to 100% |

## FY boundary test (`19_trend_analytics.sql`)

| Date | FY | Quarter | FY month | Status |
|---|---|---|---|---|
| 2023-04-01 | FY2023-24 | Q1 | 1 | PASS |
| 2024-03-31 | FY2023-24 | Q4 | 12 | PASS |
| 2024-04-01 | FY2024-25 | Q1 | 1 | PASS |
| 2025-03-31 | FY2024-25 | Q4 | 12 | PASS |

## Known limitations of the data

Synthetic data with a scaled-down network and synthetic bed capacity. Further limitations:
- left-censoring (history starts 1 Apr 2023);
- right-censoring (settlements and admissions after 31 Mar 2025 are not observed);
- no appointment-slot capacity model;
- reproducibility is guaranteed on the same PostgreSQL major version and platform.

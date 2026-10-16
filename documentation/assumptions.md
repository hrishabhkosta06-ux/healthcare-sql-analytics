# Key Assumptions (business-reader summary)

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

This page lists the assumptions a reader needs in order to interpret the results. The full technical parameter list is in [`generation_assumptions.md`](generation_assumptions.md), which is the detailed source of truth.

| # | Assumption | What it means for the results |
|---|---|---|
| 1 | **100% synthetic data** generated in PostgreSQL (seed 20250331) | No actual Apollo Hospitals operational, financial, patient or doctor data is used. Results describe the simulated dataset only |
| 2 | **Apollo is a business-context reference only** | Public Apollo facts (see [`business_context.md`](business_context.md)) frame the problem and KPI terminology. No synthetic value is calibrated to any Apollo figure |
| 3 | **Analysis period:** 1 Apr 2023 – 31 Mar 2025 | Two Indian financial years (April–March): FY2023-24 and FY2024-25 |
| 4 | **Scaled-down network:** 5 facilities, 69 operating beds | Bed capacity is a synthetic simulation parameter calibrated for analytical coherence with the generated dataset volume. It does not represent actual Apollo Hospitals facility capacity |
| 5 | **Same-day inpatient stay = 1 patient-day** | Used for LOS, ALOS, occupancy and ARPOB |
| 6 | **Net revenue is the default revenue basis** | Net = gross − discount, dated by bill_date. Procedure revenue is the exception: gross, at line level |
| 7 | **Only successful payments are collections** | Failed attempts are recorded but excluded. Outstanding = net − successful payments, and is never negative |
| 8 | **OP→IP conversion is project-defined** (30 days) | IP admission 0–30 days after a qualifying OP visit; OP visits after 1 Mar 2025 are excluded. Not Apollo's methodology |
| 9 | **ARPOB is project-defined** | Project-defined ARPOB implementation = IP net revenue ÷ IP patient-days (discharge-period attribution). Not Apollo's methodology |
| 10 | **Left-censoring** | No history exists before 1 Apr 2023, so early months over-count "new" patients |
| 11 | **Right-censoring** | Settlements and admissions after 31 Mar 2025 are not observed. Recent collection cohorts and late OP visits are incomplete |
| 12 | **No designed seasonality**, and only two FYs | Monthly peaks and troughs are not evidence of seasonality |
| 13 | **No doctor appointment-slot capacity** | Doctor workload has no booking ceiling |
| 14 | **Descriptive, not causal** | Associations (for example, lead time vs no-show) do not establish cause |
| 15 | **Many patterns are assumption-driven** | Where a result reflects a generator setting (payer mix, discounts, settlement lags, LOS, bed capacity, doctor productivity), the findings label it *Assumption-driven* and name the assumption |

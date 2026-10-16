# KPI Definitions

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

**Scope and sources:**
- Definitions are fixed and implemented in `sql/13`–`sql/19`.
- Formulas are dual-method checked in `sql/12_kpi_validation.sql`.
- All values describe the synthetic project dataset only.

**Conventions:**
- **Indian financial year** runs April–March: FY2023-24 = 1 Apr 2023 – 31 Mar 2024; FY2024-25 = 1 Apr 2024 – 31 Mar 2025.
- **FY quarters:** Q1 Apr–Jun · Q2 Jul–Sep · Q3 Oct–Dec · Q4 Jan–Mar.
- **Revenue date** = `billing.bill_date` (IP bills are dated on discharge).
- **Default revenue basis = net revenue** (`billing.net_amount`) unless a KPI states otherwise.
- **Rates** are ratios of sums, not averages of ratios. Division uses `NULLIF(denominator, 0)`.

---

## Patient KPIs

| KPI | Definition / formula | Used in |
|---|---|---|
| Total (registered) patients | Rows in `processed.patients` = 9,003 | Scope |
| Patients with ≥1 visit | COUNT(DISTINCT visits.patient_id) = 8,700. The other 303 registered patients only had cancelled or not-attended bookings | BQ-01, 06 |
| New patient (period) | Patient whose first recorded visit in the complete dataset falls inside the analysis period | BQ-03 |
| Returning patient (period) | Patient with a visit in the period and at least one visit before the period | BQ-03, 04 |
| Returning visit | A visit by a patient who has at least one earlier visit | Definition |
| New visit | The patient's first recorded visit | Definition |
| Repeat patient rate | Returning patients ÷ total patients with a visit in the period (BQ-04 uses FY2024-25; "before" means any department) | BQ-04 |
| Median interval between visits | Median of days between consecutive distinct visit dates per patient (LAG + PERCENTILE_CONT 0.5) | BQ-05 |
| Spend decile | NTILE(10) of patient total net revenue; decile share = decile revenue ÷ total. Analytical segmentation only | BQ-06 |

**Left-censoring:** history starts on 1 Apr 2023, so early months over-count "new" patients. Use FY2024-25 for retention comparisons.

## Revenue KPIs

| KPI | Definition / formula |
|---|---|
| Gross revenue | SUM(gross_amount) = sum of consultation, procedure, room, pharmacy and diagnostics charges |
| Discount | SUM(discount_amount) |
| Net revenue | SUM(net_amount) = gross − discount |
| Average bill | SUM(net_amount) ÷ COUNT(bills) |
| Revenue per visit | Net revenue ÷ visits (one bill per visit) |
| Revenue contribution / share | Dimension net revenue ÷ total net revenue (SUM() OVER ()) |
| Charge-component mix | Component total ÷ SUM(gross_amount) (gross basis) |
| Discount rate | SUM(discount_amount) ÷ SUM(gross_amount) |
| Procedure revenue | SUM(visit_procedures.charged_amount). Line-level and **gross** (before bill-level discount); reconciles to SUM(billing.procedure_charges). No bill amount is allocated across procedure lines |
| Procedure volume | SUM(quantity) (units/sessions); "times performed" = COUNT of lines |

## Payer KPIs

| KPI | Definition / formula |
|---|---|
| Revenue by payer | SUM(net_amount) by payer_type |
| Bill share | Payer bills ÷ all bills |
| Revenue share | Payer net revenue ÷ total net revenue |
| Average bill by payer | AVG(net_amount) by payer_type |

## Collection KPIs

**Rule:** only `payment_status = 'Success'` counts toward collections. Failed payments are excluded and never reduce outstanding.

| KPI | Definition / formula |
|---|---|
| Successful collections | SUM(amount_paid) WHERE payment_status = 'Success' (aggregated per bill before joining to billing) |
| Outstanding | net_amount − successful payments (per bill, then summed); always ≥ 0 |
| Collection rate | Successful payments ÷ net_amount |

**Right-censoring:** settlements after 31 Mar 2025 are not in the data. Collection rates for the latest billing cohorts are expected to be low and must be read by billing-quarter cohort.

## Appointment KPIs

| KPI | Definition / formula |
|---|---|
| Completed / Cancelled / No-show | COUNT by appointment_status (each booking has exactly one status) |
| Cancellation rate | Cancelled ÷ all bookings |
| No-show rate | No-show ÷ all bookings |
| Booking lead time | scheduled date − booking date (calendar days) |
| Lead-time buckets | Same day · 1–3 · 4–7 · 8–14 · 15+ days |

Lead-time analysis is a descriptive association only.

## OP → IP conversion (project-defined)

**30-day project-defined OP→IP conversion.** Not Apollo's methodology.

- **Qualifying OP visit:** `visit_type = 'OP'` with visit_date from 1 Apr 2023 to 1 Mar 2025.
- **Right-censoring:** OP visits after 1 Mar 2025 are excluded, because their 30-day follow-up window would run past the data cutoff.
- **Converted:** the same patient has an IP admission 0–30 days after a qualifying OP visit. A same-day admission counts.
- **Attribution:** department of the qualifying OP visit.
- **Department rate** = converted distinct patients ÷ distinct patients with a qualifying OP visit in that department. Each department's denominator is calculated independently, so a patient with qualifying OP visits in several departments contributes to several denominators.
- **Network rate:** uses distinct patients across the network.

## Inpatient KPIs

| KPI | Definition / formula |
|---|---|
| Patient-days (per stay) | GREATEST(discharge_date − admission_date, 1). A same-day IP stay = 1 day |
| ALOS | SUM(patient-days) ÷ IP discharges, attributed to the discharge period |
| Occupancy | Patient-days inside the period ÷ available bed-days × 100 |
| Available bed-days | operating_bed_count × calendar days in the period |

**Occupancy allocation:** a stay occupies nights from admission_date to admission_date + patient-days − 1. Stays crossing an FY boundary are split. Tier and network occupancy = Σ patient-days ÷ Σ bed-days, never an average of percentages.

Bed capacity is a synthetic simulation parameter calibrated for analytical coherence with the generated dataset volume. It does not represent actual Apollo Hospitals facility capacity.

## ARPOB (project-defined)

**Project-defined ARPOB implementation = IP net revenue ÷ IP patient-days (discharge-period attribution).** Not Apollo's methodology.

- **Numerator:** net_amount of IP stays discharged in the period.
- **Denominator:** patient-days of those same stays.
- **Unit:** INR per patient-day.
- **Scope:** IP only.
- **Apollo context:** Apollo historically reported ARPOB net of fee-for-service doctor fees and discontinued it from Q1 FY26 (moving to ARPP). The project calculation is not presented as Apollo's actual methodology.

## Trend KPIs

| KPI | Definition / formula |
|---|---|
| FY revenue | SUM(net_amount) by Indian FY of bill_date |
| MoM growth | (month − previous month) ÷ previous month; LAG(1) over monthly revenue |
| QoQ growth | (quarter − previous quarter) ÷ previous quarter; LAG(1) over FY quarters |
| YoY growth | Monthly: LAG(12). Quarterly: LAG(4). Available for FY2024-25 only |
| Cumulative (running) revenue | SUM(net revenue) OVER (PARTITION BY FY ORDER BY FY month), with FY month 1 = April |
| YTD growth | (cumulative FY2024-25 − cumulative FY2023-24) ÷ cumulative FY2023-24 at the same FY month |
| Peak / trough month | RANK of monthly visits within each FY (primary). Revenue rank is supplementary |

# Business Context

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

## Positioning

This is an independent portfolio project. Apollo Hospitals is used only as a publicly documented business-context reference. The project is not affiliated with, endorsed by or commissioned by Apollo Hospitals Enterprise Limited. It does not use Apollo internal data, patient records, employee or doctor records, or confidential financial information. The dataset is 100% synthetic.

The scope is **hospital services only**. Apollo HealthCo, pharmacy as a business line, digital health, retail diagnostics and insurance are excluded.

## Business problem

A multispecialty hospital network earns revenue from outpatient consultations, inpatient admissions, emergency care and day-care procedures across facilities, departments and doctors. Management needs to understand five things:

- where patient volume comes from;
- which departments, doctors, procedures and payers drive revenue;
- how efficiently beds and appointment slots are used;
- how much billed revenue is collected;
- whether growth is driven by volume or by mix.

## Public Apollo context used (framing and KPI terminology only)

Source tiers:
- **T1:** official Apollo material.
- **T2:** institutional rating agency.

Link verification (final micro-patch):
- Every linked Apollo document was located on an official Apollo domain (`apollohospitals.com` / `mediacdn.apollohospitals.com`) in search-index results, and the indexed text matches the cited content.
- Direct PDF download from apollohospitals.com is blocked by the site's bot protection, so the files were verified through their indexed text. The ICRA rationale was opened directly.
- All cited Apollo sources now have direct links. The Sep 2023 presentation is linked through Apollo’s own filing on the BSE (Bombay Stock Exchange) website.

| ID | Public context | Source (tier, date) | Status |
|---|---|---|---|
| F1 | ICRA describes Apollo Hospitals Enterprise Ltd (AHEL) as India's largest integrated private healthcare player. The README uses neutral wording ("a large integrated private healthcare group in India") and attributes any "largest" claim to ICRA | ICRA rating rationale, 18 May 2026 (T2) — https://www.icra.in/Rating/ShowRationalReportFilePdfViewer/143077 | Current, secondary, attributed |
| F2 | Business verticals: Healthcare Services, Apollo HealthCo, Apollo Health & Lifestyle. ICRA also reports a planned restructuring that keeps AHEL focused on hospital-led and retail healthcare services | Q1 FY26 earnings-call transcript, 13 Aug 2025 (T1) — https://mediacdn.apollohospitals.com/sites/default/files/2025-08/transcript-of-apollo-hospitals---q1-fy26-earnings-call---13-august-2025.pdf ; ICRA, May 2026 (T2) | Current |
| F3 | Reported hospital KPIs include bed occupancy rate (occupied bed-days ÷ operating bed-days), inpatient volume, outpatient volume, inpatient ALOS and ARPP-IP | Investor presentation, Mar 2026 (T1) — https://www.apollohospitals.com/sites/default/files/2026-06/ahel-investor-presentation-march-2026-inr.pdf ; Investor presentation, Dec 2025 (T1) — https://www.apollohospitals.com/sites/default/files/2026-02/ahel-investor-presentation-december25-inr.pdf ; Q1 FY27 earnings-call transcript, 13 Aug 2026 (T1) — https://www.apollohospitals.com/sites/default/files/2026-08/transcript-of-apollo-hospitals---q1-fy27-earnings-call.pdf | Current |
| F4 | Apollo's outpatient volume counts new registrations only. **The project does not copy this**: its OP metrics count encounters and patients | Investor presentation, Dec 2025 (T1) — https://www.apollohospitals.com/sites/default/files/2026-02/ahel-investor-presentation-december25-inr.pdf ; same footnote in Investor presentation, June 2019 (T1) — https://www.apollohospitals.com/apollo_pdf/AHEL-Investor-Presentation-June19-INR.pdf | Current as of Dec 2025 |
| F5 | ARPOB was historically reported net of fee-for-service doctor fees (total hospital revenue ÷ patient days). It was discontinued from Q1 FY26 in favour of ARPP | Investor presentation, Mar 2024 (T1) — https://apollohospitals.com/apollo_pdf/AHEL-Investor-Presentation-March24-INR.pdf ; Investor presentation, Mar 2025 (T1) — https://www.apollohospitals.com/sites/default/files/2025-07/ahel-investor-presentation-march25-inr.pdf (states the same ARPOB definition and the fee-for-service netting footnote) ; Q1 FY26 transcript (T1) — https://mediacdn.apollohospitals.com/sites/default/files/2025-08/transcript-of-apollo-hospitals---q1-fy26-earnings-call---13-august-2025.pdf | Historical / discontinued |
| F6 | ALOS defined as the average number of days patients stay in the hospital | Investor presentation, Sep 2023 (T1, stock-exchange filing of the presentation for the quarter ended 30 Sep 2023) — https://bseindia.com/xml-data/corpfiling/AttachHis/45b8350c-9cee-4c6a-890b-e0da6ec53028.pdf ; same definition stated in Investor presentation, Mar 2025 (T1) — https://www.apollohospitals.com/sites/default/files/2025-07/ahel-investor-presentation-march25-inr.pdf | Historical definition; metric still reported |
| F7 | ICRA notes that consumer touchpoints strengthen outpatient-to-inpatient conversion. **No Apollo OP→IP methodology exists**; the project's 30-day KPI is project-defined | ICRA, May 2026 (T2) | Current, context only |
| F8 | Specialty focus on cardiac, oncology, transplant, neurosciences, gastroenterology and orthopaedics. Used as context only; it does not set department weights | Q1 FY27 earnings-call transcript, 13 Aug 2026 (T1) — https://www.apollohospitals.com/sites/default/files/2026-08/transcript-of-apollo-hospitals---q1-fy27-earnings-call.pdf | Current, context only |

## Boundary between Apollo facts and project methodology

| Apollo public context (above) | Project-defined synthetic methodology |
|---|---|
| Frames the business problem and KPI vocabulary | Facilities, doctors, patients, visits, prices, payer mix, LOS, bed capacity and all distributions ([`generation_assumptions.md`](generation_assumptions.md)) |
| Never used as a generation target | Project-defined ARPOB, 30-day OP→IP conversion, occupancy allocation ([`kpi_definitions.md`](kpi_definitions.md)) |

Findings are always written as "in the synthetic project dataset" and are never stated as Apollo's performance.

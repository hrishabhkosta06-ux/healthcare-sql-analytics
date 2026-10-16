# Data Dictionary

**Project:** Apollo Hospitals — Healthcare Operations & Revenue Analytics using SQL

**Scope:**
- Schema `processed` (the analytics layer).
- `raw` has identical columns, but its categorical columns are unconstrained so that the documented data-quality issues can load. See `data_quality_report.md`.

**Data and verification:**
- All data is synthetic; names are fictitious.
- Types and nullability were verified against `information_schema.columns`.
- Keys were verified against `information_schema.table_constraints`.
- Source DDL: `sql/01_schema.sql`.

**Conventions:**
- Money is `numeric(12,2)` in INR.
- Dates are `date`. Booking times are `timestamp`, without time zone.
- Indian FY runs April–March.
- "Example" values illustrate the format of each column; they are not quotations of specific records (IDs follow the real numbering pattern).

| # | Table | Grain | Rows |
|---|---|---|---|
| 1 | facilities | one row per synthetic hospital | 5 |
| 2 | departments | one row per clinical specialty | 14 |
| 3 | doctors | one row per doctor | 72 |
| 4 | patients | one row per processed (deduplicated) registered patient | 9,003 |
| 5 | appointments | one row per appointment booking (OP slot) | 40,866 |
| 6 | visits | one row per healthcare encounter (OP, IP, ER, Day-care) | 43,714 |
| 7 | procedures | one row per catalogue procedure | 57 |
| 8 | visit_procedures | one row per procedure line associated with a visit | 17,366 |
| 9 | billing | one row per visit (one bill per visit) | 43,714 |
| 10 | payments | one row per payment attempt/transaction (a bill can have 0, 1 or many) | 45,058 |

---

## 1. facilities
**Purpose:** The hospitals in the synthetic network. **Grain:** one row per facility. **PK:** `facility_id`.

**Relationships:** referenced by `doctors`, `appointments`, `visits` and `patients.registration_facility_id`.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| facility_id | varchar(6) | NO | Facility identifier (PK) | FAC001 |
| facility_name | varchar(100) | NO | Synthetic facility name (unique) | Simulated Hospital A (Mumbai) |
| city | varchar(50) | NO | City where the facility is located | Mumbai |
| city_tier | varchar(10) | NO | `Metro` or `Non-metro` | Metro |
| operating_bed_count | integer | NO | Operating beds (10–25), the occupancy denominator. Bed capacity is a synthetic simulation parameter calibrated for analytical coherence with the generated dataset volume. It does not represent actual Apollo Hospitals facility capacity. | 18 |
| opened_date | date | NO | Opening date (before 1 Apr 2023, so capacity is constant across the window) | 2012-06-15 |

## 2. departments
**Purpose:** Clinical specialties. **Grain:** one row per department. **PK:** `department_id`.

**Relationships:** referenced by `doctors`, `procedures` and `visits`.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| department_id | varchar(5) | NO | Department identifier (PK) | DEP03 |
| department_name | varchar(60) | NO | Specialty name (unique) | Cardiology |
| department_category | varchar(12) | NO | `Medical`, `Surgical`, `Diagnostic` or `Emergency` | Medical |

## 3. doctors
**Purpose:** Clinicians. Each doctor belongs to one department and one facility. **Grain:** one row per doctor. **PK:** `doctor_id`.

**FKs:** `department_id` → departments; `facility_id` → facilities.

**Relationships:** referenced by `appointments` (booked doctor) and `visits` (attending doctor).

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| doctor_id | varchar(6) | NO | Doctor identifier (PK) | DOC004 |
| doctor_name | varchar(100) | NO | Synthetic name | Dr. Siddharth Sharma |
| department_id | varchar(5) | NO | Home department (FK) | DEP03 |
| facility_id | varchar(6) | NO | Home facility (FK) | FAC001 |
| designation | varchar(25) | NO | `Associate Consultant`, `Consultant` or `Senior Consultant` | Consultant |
| years_experience | smallint | NO | Years of experience (0–60) | 12 |
| consultation_fee | numeric(10,2) | NO | OP consultation tariff (INR) | 1000.00 |
| join_date | date | NO | Date joined; no booking or visit precedes it | 2019-08-01 |

## 4. patients
**Purpose:** Registered patients. **Grain:** one row per processed patient (118 duplicate-like raw records merged). **PK:** `patient_id`.

**FK:** `registration_facility_id` → facilities.

**Relationships:** referenced by `appointments` and `visits`.

**Note:** 9,003 registered patients; 8,700 have at least one visit. The other 303 only had bookings that were cancelled or not attended.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| patient_id | varchar(8) | NO | Patient identifier (PK); survivor ID after merge | PAT00001 |
| patient_name | varchar(100) | NO | Synthetic name (trimmed) | Rohan Verma |
| gender | varchar(10) | NO | `Male`, `Female` or `Other` | Female |
| date_of_birth | date | NO | Date of birth (before registration_date) | 1978-11-03 |
| city | varchar(50) | NO | City of residence (standardised casing) | Pune |
| state | varchar(50) | NO | State of residence | Maharashtra |
| registration_date | date | NO | First contact: earliest booking date or visit date, within the window | 2023-04-12 |
| registration_facility_id | varchar(6) | NO | Facility of first contact (FK) | FAC001 |

## 5. appointments
**Purpose:** Booked outpatient slots. **Grain:** one row per appointment booking. **PK:** `appointment_id`.

**FKs:** `patient_id`, `doctor_id`, `facility_id`.

**Relationship to visits:** 1 appointment → 0 or 1 visit. Only `Completed` appointments create a visit.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| appointment_id | varchar(10) | NO | Booking identifier (PK) | APT000001 |
| patient_id | varchar(8) | NO | Booking patient (FK) | PAT00001 |
| doctor_id | varchar(6) | NO | Booked doctor (FK) | DOC004 |
| facility_id | varchar(6) | NO | Facility; equals the doctor's facility (FK) | FAC001 |
| booking_datetime | timestamp | NO | When the booking was made (≥ 2023-04-01 and ≤ scheduled_datetime) | 2023-05-02 10:14 |
| scheduled_datetime | timestamp | NO | Appointment slot (Mon–Sat, 09:00–16:45) | 2023-05-09 11:30 |
| appointment_status | varchar(12) | NO | `Completed`, `Cancelled` or `No-show` | Completed |
| cancellation_reason | varchar(40) | YES | Populated only when `Cancelled`. `Not recorded` where the reason was missing | Patient Request |
| booking_channel | varchar(20) | NO | `Phone`, `Website`, `Mobile App`, `Front Desk` or `Unknown` (not captured) | Mobile App |

## 6. visits
**Purpose:** Healthcare encounters. **Grain:** one row per encounter (`OP`, `IP`, `ER`, `Day-care`). **PK:** `visit_id`.

**FKs:** `patient_id`, `doctor_id`, `department_id`, `facility_id`, and `appointment_id` (nullable, unique).

**Relationships:**
- 1 visit → exactly 1 billing record.
- 1 visit → 0..* visit_procedures.

**Key rules:**
- IP-only fields are populated if and only if `visit_type = 'IP'`.
- No overlapping IP stays per patient.
- No OP/ER/Day-care visit strictly between a patient's admission and discharge dates (IC-01).

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| visit_id | varchar(10) | NO | Encounter identifier (PK), date-ordered | VIS000001 |
| patient_id | varchar(8) | NO | Patient (FK) | PAT00001 |
| doctor_id | varchar(6) | NO | Attending doctor (FK); basis of doctor attribution | DOC004 |
| department_id | varchar(5) | NO | Department; equals the doctor's department (FK) | DEP03 |
| facility_id | varchar(6) | NO | Facility; equals the doctor's facility (FK) | FAC001 |
| appointment_id | varchar(10) | YES | Source booking for appointment-linked OP visits; NULL for walk-in OP, ER, IP and Day-care (FK, unique) | APT000001 |
| visit_type | varchar(10) | NO | `OP`, `IP`, `ER` or `Day-care` | OP |
| visit_date | date | NO | Encounter date (for IP, equals admission_date) | 2024-01-15 |
| admission_date | date | YES | IP admission date (IP only) | 2024-01-15 |
| discharge_date | date | YES | IP discharge date (IP only; ≤ 2025-03-31, no open stays) | 2024-01-19 |
| discharge_status | varchar(20) | YES | `Discharged`, `Transferred` or `LAMA` (IP only) | Discharged |

## 7. procedures
**Purpose:** Procedure catalogue. **Grain:** one row per procedure. **PK:** `procedure_id`.

**FK:** `department_id` → departments.

**Relationships:** referenced by `visit_procedures`.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| procedure_id | varchar(6) | NO | Procedure identifier (PK) | PRC009 |
| procedure_name | varchar(100) | NO | Generic procedure name (unique) | Coronary Angiography |
| department_id | varchar(5) | NO | Owning department (FK) | DEP03 |
| procedure_category | varchar(20) | NO | `Diagnostic`, `Minor Procedure`, `Interventional`, `Major Surgery` or `Therapy Session` | Interventional |
| standard_price | numeric(12,2) | NO | FY2023-24 list tariff (synthetic, INR) | 27500.00 |

## 8. visit_procedures
**Purpose:** Bridge between visits and procedures (many-to-many). **Grain:** one row per procedure line associated with a visit. **PK:** `visit_procedure_id`.

**FKs:** `visit_id` → visits; `procedure_id` → procedures.

**Rules:**
- The procedure's department equals the visit's department.
- SUM(`charged_amount`) per visit = `billing.procedure_charges`.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| visit_procedure_id | varchar(10) | NO | Line identifier (PK) | VPR000001 |
| visit_id | varchar(10) | NO | Encounter (FK) | VIS000123 |
| procedure_id | varchar(6) | NO | Procedure (FK) | PRC009 |
| procedure_date | date | NO | Date performed (within the stay for IP; equals visit_date otherwise) | 2024-01-16 |
| quantity | smallint | NO | Units/sessions (≥ 1) | 1 |
| charged_amount | numeric(12,2) | NO | Line charge, **gross** (before the bill-level discount) | 28142.55 |

## 9. billing
**Purpose:** Invoices. **Grain:** one row per visit (exactly one bill per visit). **PK:** `bill_id`.

**FK:** `visit_id` → visits (unique).

**Relationships:** 1 bill → 0..* payments.

**Rules:**
- `gross_amount` = sum of the five charge components.
- `net_amount` = `gross_amount` − `discount_amount`.
- `bill_date` = discharge_date for IP, otherwise visit_date.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| bill_id | varchar(10) | NO | Bill identifier (PK) | BIL000001 |
| visit_id | varchar(10) | NO | Billed encounter (FK, unique) | VIS000001 |
| bill_date | date | NO | Revenue date | 2024-01-19 |
| consultation_charges | numeric(12,2) | NO | Doctor or ER fees | 5000.00 |
| procedure_charges | numeric(12,2) | NO | Sum of visit_procedures.charged_amount | 28142.55 |
| room_charges | numeric(12,2) | NO | IP bed charges (0 for non-IP) | 36000.00 |
| pharmacy_charges | numeric(12,2) | NO | Medicines | 9850.20 |
| diagnostics_charges | numeric(12,2) | NO | Lab/imaging not itemised as procedures | 7420.10 |
| gross_amount | numeric(12,2) | NO | Sum of the five components | 86412.85 |
| discount_amount | numeric(12,2) | NO | Discount (0 ≤ discount ≤ gross) | 0.00 |
| net_amount | numeric(12,2) | NO | **Net revenue** (> 0); default revenue basis | 86412.85 |
| payer_type | varchar(20) | NO | `Self-pay`, `Insurance-TPA`, `Corporate` or `Govt scheme` | Insurance-TPA |

## 10. payments
**Purpose:** Payment attempts and settlements. **Grain:** one row per payment attempt/transaction. A bill can have zero (unpaid), one or many rows. **PK:** `payment_id`.

**FK:** `bill_id` → billing.

**Rules:**
- Only `Success` rows count toward collections.
- SUM(`Success`) per bill ≤ `net_amount`.
- `Failed` rows are recorded attempts and never reduce outstanding.

| Column | Type | Null | Definition | Example |
|---|---|---|---|---|
| payment_id | varchar(10) | NO | Payment identifier (PK) | PAY000001 |
| bill_id | varchar(10) | NO | Bill paid (FK) | BIL000001 |
| payment_date | date | NO | Payment date (≥ bill_date, ≤ 2025-03-31) | 2024-02-20 |
| amount_paid | numeric(12,2) | NO | Amount paid or attempted (> 0) | 86412.85 |
| payment_mode | varchar(25) | NO | `Cash`, `UPI`, `Card`, `Net Banking`, `Insurance Settlement`, `Corporate Settlement` or `Govt Scheme Settlement` | Insurance Settlement |
| payment_status | varchar(10) | NO | `Success` or `Failed` | Success |

---

## Relationship summary (16 foreign keys)

| Parent | Child | Cardinality |
|---|---|---|
| facilities | doctors, appointments, visits, patients (registration) | 1 : 0..* |
| departments | doctors, procedures, visits | 1 : 0..* |
| patients | appointments, visits | 1 : 0..* |
| doctors | appointments, visits | 1 : 0..* |
| appointments | visits | 1 : 0..1 (Completed only) |
| visits | visit_procedures | 1 : 0..* |
| procedures | visit_procedures | 1 : 0..* |
| visits | billing | 1 : 1 |
| billing | payments | 1 : 0..* |

Diagram: [`erd.png`](erd.png)

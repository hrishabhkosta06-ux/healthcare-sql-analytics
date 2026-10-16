/* =============================================================================
   01_schema.sql
   Apollo Hospitals - Healthcare Operations & Revenue Analytics using SQL
   (Independent portfolio project. 100% synthetic data. Not Apollo data.)

   Creates:
     gen        - deterministic random-number functions + read-only parameter
                  views used by the SQL generator (no data tables)
     raw        - the 10 core tables as generated (contains deliberate,
                  documented non-key data-quality issues)
     processed  - the same 10 tables after SQL cleaning, with full CHECK
                  constraints (analytics will read ONLY from processed)

   Note: CHECK constraints cannot reference other tables in PostgreSQL.
   Cross-table rules are verified by 09_data_quality_validation.sql.
   Target: PostgreSQL 14+ (developed and executed on PostgreSQL 16).
   ========================================================================== */

DROP SCHEMA IF EXISTS processed CASCADE;
DROP SCHEMA IF EXISTS raw       CASCADE;
DROP SCHEMA IF EXISTS gen       CASCADE;

CREATE SCHEMA gen;
CREATE SCHEMA raw;
CREATE SCHEMA processed;

/* -----------------------------------------------------------------------------
   gen: deterministic pseudo-random functions
   Why not random()/setseed()? random() is deterministic only for an identical
   sequence of calls; the call order can change with the query plan
   (join order, parallel workers). Instead every draw is a hash of
   (seed | draw-key), so a value depends only on WHAT is being drawn,
   never on execution order. Same seed + same scripts = same dataset.
   -------------------------------------------------------------------------- */

-- Uniform [0,1) from the first 52 bits of md5(seed | key)
CREATE FUNCTION gen.u(p_key text)
RETURNS double precision
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT (('x' || substr(md5(
               coalesce(nullif(current_setting('apollo.seed', true), ''), '20250331')
               || '|' || p_key), 1, 13))::bit(52)::bigint)::double precision
           / 4503599627370496.0          -- 2^52
$$;

-- Integer uniform in [p_lo, p_hi]
CREATE FUNCTION gen.ri(p_key text, p_lo int, p_hi int)
RETURNS int
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT p_lo + floor(gen.u(p_key) * (p_hi - p_lo + 1))::int
$$;

-- Continuous uniform in [p_lo, p_hi)
CREATE FUNCTION gen.ur(p_key text, p_lo double precision, p_hi double precision)
RETURNS double precision
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT p_lo + gen.u(p_key) * (p_hi - p_lo)
$$;

-- Exponential with given mean (inverse-CDF method)
CREATE FUNCTION gen.expo(p_key text, p_mean double precision)
RETURNS double precision
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT -p_mean * ln(1.0 - gen.u(p_key))
$$;

-- Standard normal (Box-Muller)
CREATE FUNCTION gen.normal(p_key text)
RETURNS double precision
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT sqrt(-2.0 * ln(1.0 - gen.u(p_key || ':n1')))
         * cos(2.0 * pi() * gen.u(p_key || ':n2'))
$$;

/* -----------------------------------------------------------------------------
   gen: parameter view (single place for every generation constant).
   All values are PORTFOLIO SIMULATION ASSUMPTIONS (see
   documentation/generation_assumptions.md). None is an Apollo figure.
   -------------------------------------------------------------------------- */
CREATE VIEW gen.v_params AS
SELECT
    DATE '2023-04-01'  AS window_start,
    DATE '2025-03-31'  AS window_end,
    9600               AS candidate_patients,      -- A-01 (event-less ones are removed)
    0.18               AS minor_share,             -- A-02
    8.3                AS appt_count_mean,         -- A-05 appointments per patient (exp. mean, pre-truncation)
    25                 AS appt_count_cap,
    52.0               AS appt_gap_mean_days,      -- A-05
    0.85               AS home_facility_share,
    0.70               AS primary_dept_share,
    0.76               AS p_completed,             -- A-16 (independent of everything)
    0.12               AS p_cancelled,             -- A-16 (no-show = remainder 0.12)
    0.15               AS er_origin_share,         -- A-21 share of IP stays with ER visit on admission day
    0.50               AS op_referred_share_surgical, -- A-21
    0.30               AS op_referred_share_medical,  -- A-21
    1000               AS walkin_op_candidates,    -- A-03
    1800               AS er_candidates,           -- A-03
    1600               AS daycare_candidates,      -- A-03
    0.03               AS same_day_ip_share,       -- A-19
    30                 AS los_cap_days,            -- A-19
    0.02               AS dq_patient_dup_share_of_eligible, -- A-22 (applied to patients with >=4 events)
    gen.ur('tariff:fy2uplift', 0.03, 0.06) AS fy2_tariff_uplift -- A-08 (drawn once, not chosen)
;

/* -----------------------------------------------------------------------------
   RAW SCHEMA (as generated). Keys, FKs and NOT NULL on structural columns.
   Categorical columns are deliberately unconstrained so that documented
   label/casing issues can load. Amounts and dates are clean.
   -------------------------------------------------------------------------- */
CREATE TABLE raw.facilities (
    facility_id          VARCHAR(6)   PRIMARY KEY,
    facility_name        VARCHAR(100) NOT NULL,
    city                 VARCHAR(50)  NOT NULL,
    city_tier            VARCHAR(10)  NOT NULL,
    operating_bed_count  INTEGER      NOT NULL CHECK (operating_bed_count > 0),
    opened_date          DATE         NOT NULL
);

CREATE TABLE raw.departments (
    department_id        VARCHAR(5)   PRIMARY KEY,
    department_name      VARCHAR(60)  NOT NULL,
    department_category  VARCHAR(12)  NOT NULL
);

CREATE TABLE raw.doctors (
    doctor_id            VARCHAR(6)    PRIMARY KEY,
    doctor_name          VARCHAR(100)  NOT NULL,
    department_id        VARCHAR(5)    NOT NULL REFERENCES raw.departments,
    facility_id          VARCHAR(6)    NOT NULL REFERENCES raw.facilities,
    designation          VARCHAR(25)   NOT NULL,
    years_experience     SMALLINT      NOT NULL,
    consultation_fee     NUMERIC(10,2) NOT NULL,
    join_date            DATE          NOT NULL
);

CREATE TABLE raw.patients (
    patient_id               VARCHAR(8)   PRIMARY KEY,
    patient_name             VARCHAR(100) NOT NULL,
    gender                   VARCHAR(10)  NOT NULL,
    date_of_birth            DATE         NOT NULL,
    city                     VARCHAR(50)  NOT NULL,
    state                    VARCHAR(50)  NOT NULL,
    registration_date        DATE         NOT NULL,
    registration_facility_id VARCHAR(6)   NOT NULL REFERENCES raw.facilities
);

CREATE TABLE raw.appointments (
    appointment_id       VARCHAR(10)  PRIMARY KEY,
    patient_id           VARCHAR(8)   NOT NULL REFERENCES raw.patients,
    doctor_id            VARCHAR(6)   NOT NULL REFERENCES raw.doctors,
    facility_id          VARCHAR(6)   NOT NULL REFERENCES raw.facilities,
    booking_datetime     TIMESTAMP    NOT NULL,
    scheduled_datetime   TIMESTAMP    NOT NULL,
    appointment_status   VARCHAR(12)  NOT NULL,
    cancellation_reason  VARCHAR(40),
    booking_channel      VARCHAR(20)
);

CREATE TABLE raw.visits (
    visit_id          VARCHAR(10)  PRIMARY KEY,
    patient_id        VARCHAR(8)   NOT NULL REFERENCES raw.patients,
    doctor_id         VARCHAR(6)   NOT NULL REFERENCES raw.doctors,
    department_id     VARCHAR(5)   NOT NULL REFERENCES raw.departments,
    facility_id       VARCHAR(6)   NOT NULL REFERENCES raw.facilities,
    appointment_id    VARCHAR(10)  UNIQUE REFERENCES raw.appointments,
    visit_type        VARCHAR(10)  NOT NULL,
    visit_date        DATE         NOT NULL,
    admission_date    DATE,
    discharge_date    DATE,
    discharge_status  VARCHAR(20)
);

CREATE TABLE raw.procedures (
    procedure_id        VARCHAR(6)    PRIMARY KEY,
    procedure_name      VARCHAR(100)  NOT NULL,
    department_id       VARCHAR(5)    NOT NULL REFERENCES raw.departments,
    procedure_category  VARCHAR(20)   NOT NULL,
    standard_price      NUMERIC(12,2) NOT NULL CHECK (standard_price > 0)
);

CREATE TABLE raw.visit_procedures (
    visit_procedure_id  VARCHAR(10)   PRIMARY KEY,
    visit_id            VARCHAR(10)   NOT NULL REFERENCES raw.visits,
    procedure_id        VARCHAR(6)    NOT NULL REFERENCES raw.procedures,
    procedure_date      DATE          NOT NULL,
    quantity            SMALLINT      NOT NULL CHECK (quantity >= 1),
    charged_amount      NUMERIC(12,2) NOT NULL CHECK (charged_amount > 0)
);

CREATE TABLE raw.billing (
    bill_id               VARCHAR(10)   PRIMARY KEY,
    visit_id              VARCHAR(10)   NOT NULL UNIQUE REFERENCES raw.visits,
    bill_date             DATE          NOT NULL,
    consultation_charges  NUMERIC(12,2) NOT NULL,
    procedure_charges     NUMERIC(12,2) NOT NULL,
    room_charges          NUMERIC(12,2) NOT NULL,
    pharmacy_charges      NUMERIC(12,2) NOT NULL,
    diagnostics_charges   NUMERIC(12,2) NOT NULL,
    gross_amount          NUMERIC(12,2) NOT NULL,
    discount_amount       NUMERIC(12,2) NOT NULL,
    net_amount            NUMERIC(12,2) NOT NULL,
    payer_type            VARCHAR(20)   NOT NULL
);

CREATE TABLE raw.payments (
    payment_id      VARCHAR(10)   PRIMARY KEY,
    bill_id         VARCHAR(10)   NOT NULL REFERENCES raw.billing,
    payment_date    DATE          NOT NULL,
    amount_paid     NUMERIC(12,2) NOT NULL CHECK (amount_paid > 0),
    payment_mode    VARCHAR(25)   NOT NULL,
    payment_status  VARCHAR(10)   NOT NULL
);

-- Raw indexes: only those the generator's joins need
CREATE INDEX ix_raw_appt_patient   ON raw.appointments (patient_id);
CREATE INDEX ix_raw_visit_patient  ON raw.visits (patient_id);
CREATE INDEX ix_raw_vp_visit       ON raw.visit_procedures (visit_id);
CREATE INDEX ix_raw_pay_bill       ON raw.payments (bill_id);

/* -----------------------------------------------------------------------------
   PROCESSED SCHEMA (analytics-ready). Same columns, full single-table CHECKs.
   -------------------------------------------------------------------------- */
CREATE TABLE processed.facilities (
    facility_id          VARCHAR(6)   PRIMARY KEY,
    facility_name        VARCHAR(100) NOT NULL UNIQUE,
    city                 VARCHAR(50)  NOT NULL,
    city_tier            VARCHAR(10)  NOT NULL CHECK (city_tier IN ('Metro','Non-metro')),
    operating_bed_count  INTEGER      NOT NULL CHECK (operating_bed_count BETWEEN 10 AND 25),
    opened_date          DATE         NOT NULL CHECK (opened_date < DATE '2023-04-01')
);

CREATE TABLE processed.departments (
    department_id        VARCHAR(5)   PRIMARY KEY,
    department_name      VARCHAR(60)  NOT NULL UNIQUE,
    department_category  VARCHAR(12)  NOT NULL
        CHECK (department_category IN ('Medical','Surgical','Diagnostic','Emergency'))
);

CREATE TABLE processed.doctors (
    doctor_id            VARCHAR(6)    PRIMARY KEY,
    doctor_name          VARCHAR(100)  NOT NULL,
    department_id        VARCHAR(5)    NOT NULL REFERENCES processed.departments,
    facility_id          VARCHAR(6)    NOT NULL REFERENCES processed.facilities,
    designation          VARCHAR(25)   NOT NULL
        CHECK (designation IN ('Associate Consultant','Consultant','Senior Consultant')),
    years_experience     SMALLINT      NOT NULL CHECK (years_experience BETWEEN 0 AND 60),
    consultation_fee     NUMERIC(10,2) NOT NULL CHECK (consultation_fee > 0),
    join_date            DATE          NOT NULL CHECK (join_date <= DATE '2025-03-31')
);

CREATE TABLE processed.patients (
    patient_id               VARCHAR(8)   PRIMARY KEY,
    patient_name             VARCHAR(100) NOT NULL CHECK (patient_name = btrim(patient_name)),
    gender                   VARCHAR(10)  NOT NULL CHECK (gender IN ('Male','Female','Other')),
    date_of_birth            DATE         NOT NULL,
    city                     VARCHAR(50)  NOT NULL CHECK (city = btrim(city)),
    state                    VARCHAR(50)  NOT NULL,
    registration_date        DATE         NOT NULL
        CHECK (registration_date BETWEEN DATE '2023-04-01' AND DATE '2025-03-31'),
    registration_facility_id VARCHAR(6)   NOT NULL REFERENCES processed.facilities,
    CHECK (date_of_birth < registration_date)
);

CREATE TABLE processed.appointments (
    appointment_id       VARCHAR(10)  PRIMARY KEY,
    patient_id           VARCHAR(8)   NOT NULL REFERENCES processed.patients,
    doctor_id            VARCHAR(6)   NOT NULL REFERENCES processed.doctors,
    facility_id          VARCHAR(6)   NOT NULL REFERENCES processed.facilities,
    booking_datetime     TIMESTAMP    NOT NULL,
    scheduled_datetime   TIMESTAMP    NOT NULL,
    appointment_status   VARCHAR(12)  NOT NULL
        CHECK (appointment_status IN ('Completed','Cancelled','No-show')),
    cancellation_reason  VARCHAR(40),
    booking_channel      VARCHAR(20)  NOT NULL
        CHECK (booking_channel IN ('Phone','Website','Mobile App','Front Desk','Unknown')),
    CHECK (booking_datetime <= scheduled_datetime),
    CHECK (booking_datetime >= TIMESTAMP '2023-04-01 00:00:00'),
    CHECK (scheduled_datetime < TIMESTAMP '2025-04-01 00:00:00'),
    CHECK ((appointment_status = 'Cancelled') = (cancellation_reason IS NOT NULL))
);

CREATE TABLE processed.visits (
    visit_id          VARCHAR(10)  PRIMARY KEY,
    patient_id        VARCHAR(8)   NOT NULL REFERENCES processed.patients,
    doctor_id         VARCHAR(6)   NOT NULL REFERENCES processed.doctors,
    department_id     VARCHAR(5)   NOT NULL REFERENCES processed.departments,
    facility_id       VARCHAR(6)   NOT NULL REFERENCES processed.facilities,
    appointment_id    VARCHAR(10)  UNIQUE REFERENCES processed.appointments,
    visit_type        VARCHAR(10)  NOT NULL CHECK (visit_type IN ('OP','IP','ER','Day-care')),
    visit_date        DATE         NOT NULL
        CHECK (visit_date BETWEEN DATE '2023-04-01' AND DATE '2025-03-31'),
    admission_date    DATE,
    discharge_date    DATE CHECK (discharge_date <= DATE '2025-03-31'),
    discharge_status  VARCHAR(20)
        CHECK (discharge_status IN ('Discharged','Transferred','LAMA')),
    CHECK ((visit_type = 'IP') = (admission_date   IS NOT NULL)),
    CHECK ((visit_type = 'IP') = (discharge_date   IS NOT NULL)),
    CHECK ((visit_type = 'IP') = (discharge_status IS NOT NULL)),
    CHECK (discharge_date >= admission_date),
    CHECK (visit_type <> 'IP' OR visit_date = admission_date),
    CHECK (appointment_id IS NULL OR visit_type = 'OP')
);

CREATE TABLE processed.procedures (
    procedure_id        VARCHAR(6)    PRIMARY KEY,
    procedure_name      VARCHAR(100)  NOT NULL UNIQUE,
    department_id       VARCHAR(5)    NOT NULL REFERENCES processed.departments,
    procedure_category  VARCHAR(20)   NOT NULL CHECK (procedure_category IN
        ('Diagnostic','Minor Procedure','Interventional','Major Surgery','Therapy Session')),
    standard_price      NUMERIC(12,2) NOT NULL CHECK (standard_price > 0)
);

CREATE TABLE processed.visit_procedures (
    visit_procedure_id  VARCHAR(10)   PRIMARY KEY,
    visit_id            VARCHAR(10)   NOT NULL REFERENCES processed.visits,
    procedure_id        VARCHAR(6)    NOT NULL REFERENCES processed.procedures,
    procedure_date      DATE          NOT NULL,
    quantity            SMALLINT      NOT NULL CHECK (quantity >= 1),
    charged_amount      NUMERIC(12,2) NOT NULL CHECK (charged_amount > 0)
);

CREATE TABLE processed.billing (
    bill_id               VARCHAR(10)   PRIMARY KEY,
    visit_id              VARCHAR(10)   NOT NULL UNIQUE REFERENCES processed.visits,
    bill_date             DATE          NOT NULL
        CHECK (bill_date BETWEEN DATE '2023-04-01' AND DATE '2025-03-31'),
    consultation_charges  NUMERIC(12,2) NOT NULL CHECK (consultation_charges >= 0),
    procedure_charges     NUMERIC(12,2) NOT NULL CHECK (procedure_charges    >= 0),
    room_charges          NUMERIC(12,2) NOT NULL CHECK (room_charges         >= 0),
    pharmacy_charges      NUMERIC(12,2) NOT NULL CHECK (pharmacy_charges     >= 0),
    diagnostics_charges   NUMERIC(12,2) NOT NULL CHECK (diagnostics_charges  >= 0),
    gross_amount          NUMERIC(12,2) NOT NULL,
    discount_amount       NUMERIC(12,2) NOT NULL CHECK (discount_amount >= 0),
    net_amount            NUMERIC(12,2) NOT NULL CHECK (net_amount > 0),
    payer_type            VARCHAR(20)   NOT NULL
        CHECK (payer_type IN ('Self-pay','Insurance-TPA','Corporate','Govt scheme')),
    CHECK (gross_amount = consultation_charges + procedure_charges + room_charges
                          + pharmacy_charges + diagnostics_charges),
    CHECK (discount_amount <= gross_amount),
    CHECK (net_amount = gross_amount - discount_amount)
);

CREATE TABLE processed.payments (
    payment_id      VARCHAR(10)   PRIMARY KEY,
    bill_id         VARCHAR(10)   NOT NULL REFERENCES processed.billing,
    payment_date    DATE          NOT NULL CHECK (payment_date <= DATE '2025-03-31'),
    amount_paid     NUMERIC(12,2) NOT NULL CHECK (amount_paid > 0),
    payment_mode    VARCHAR(25)   NOT NULL CHECK (payment_mode IN
        ('Cash','UPI','Card','Net Banking','Insurance Settlement',
         'Corporate Settlement','Govt Scheme Settlement')),
    payment_status  VARCHAR(10)   NOT NULL CHECK (payment_status IN ('Success','Failed'))
);

/* -----------------------------------------------------------------------------
   Processed indexes (justified; see documentation/generation_assumptions.md §7, index rationale)
   - FK columns used in the BQ joins (PostgreSQL does not index FKs automatically)
   - date columns used for month/FY filtering and range checks
   -------------------------------------------------------------------------- */
CREATE INDEX ix_appt_patient     ON processed.appointments (patient_id);
CREATE INDEX ix_appt_doctor      ON processed.appointments (doctor_id);
CREATE INDEX ix_appt_scheduled   ON processed.appointments (scheduled_datetime);
CREATE INDEX ix_visit_patient    ON processed.visits (patient_id, visit_date);
CREATE INDEX ix_visit_doctor     ON processed.visits (doctor_id);
CREATE INDEX ix_visit_dept       ON processed.visits (department_id);
CREATE INDEX ix_visit_facility   ON processed.visits (facility_id, visit_date);
CREATE INDEX ix_vp_visit         ON processed.visit_procedures (visit_id);
CREATE INDEX ix_vp_procedure     ON processed.visit_procedures (procedure_id);
CREATE INDEX ix_bill_date        ON processed.billing (bill_date);
CREATE INDEX ix_pay_bill         ON processed.payments (bill_id);

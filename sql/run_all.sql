/* =============================================================================
   run_all.sql - data build and core validation (01–12), from repository root:

       createdb apollo_analytics
       psql -d apollo_analytics -f sql/run_all.sql

   Analytics scripts 13–19 must be run separately. SQL errors stop execution;
   validation rows showing FAIL must also be inspected.
   Re-running rebuilds everything from scratch
   (01_schema.sql drops and recreates the gen/raw/processed schemas).
   ========================================================================== */
\set ON_ERROR_STOP on
\timing on

-- Generator seed. Same seed + same scripts = same dataset (see 01_schema.sql).
SET apollo.seed = '20250331';

\echo '=== 01 schema ==='
\i sql/01_schema.sql
\echo '=== 02 reference data (facilities, departments, procedures, doctors) ==='
\i sql/02_reference_data.sql
\echo '=== 03 patients ==='
\i sql/03_generate_patients.sql
\echo '=== 04 appointments ==='
\i sql/04_generate_appointments.sql
\echo '=== 05 visits (IP bed timelines, OP, ER, Day-care) ==='
\i sql/05_generate_visits.sql
\echo '=== 06 visit procedures ==='
\i sql/06_generate_procedures.sql
\echo '=== 07 billing ==='
\i sql/07_generate_billing.sql
\echo '=== 08 payments ==='
\i sql/08_generate_payments.sql

\echo '=== 09 validation on RAW (DQ_FOUND expected only for D01-D08) ==='
SET search_path = raw;
\i sql/09_data_quality_validation.sql

\echo '=== 10 cleaning raw -> processed ==='
RESET search_path;
\i sql/10_data_cleaning.sql

\echo '=== 09 validation on PROCESSED (all checks must PASS) ==='
SET search_path = processed;
\i sql/09_data_quality_validation.sql

\echo '=== 11 reconciliation ==='
\i sql/11_reconciliation.sql
\echo '=== 12 KPI validation ==='
\i sql/12_kpi_validation.sql

\echo '=== Row counts (processed) ==='
SELECT 'facilities' AS table_name, count(*) AS row_count FROM processed.facilities
UNION ALL SELECT 'departments',      count(*) FROM processed.departments
UNION ALL SELECT 'doctors',          count(*) FROM processed.doctors
UNION ALL SELECT 'patients',         count(*) FROM processed.patients
UNION ALL SELECT 'appointments',     count(*) FROM processed.appointments
UNION ALL SELECT 'visits',           count(*) FROM processed.visits
UNION ALL SELECT 'procedures',       count(*) FROM processed.procedures
UNION ALL SELECT 'visit_procedures', count(*) FROM processed.visit_procedures
UNION ALL SELECT 'billing',          count(*) FROM processed.billing
UNION ALL SELECT 'payments',         count(*) FROM processed.payments;

\echo '=== Reproducibility fingerprint (compare across runs / machines) ==='
SELECT 'patients' AS table_name, md5(string_agg(t::text, '|' ORDER BY patient_id)) AS fingerprint FROM processed.patients t
UNION ALL SELECT 'appointments', md5(string_agg(t::text, '|' ORDER BY appointment_id)) FROM processed.appointments t
UNION ALL SELECT 'visits',       md5(string_agg(t::text, '|' ORDER BY visit_id))       FROM processed.visits t
UNION ALL SELECT 'visit_procedures', md5(string_agg(t::text, '|' ORDER BY visit_procedure_id)) FROM processed.visit_procedures t
UNION ALL SELECT 'billing',      md5(string_agg(t::text, '|' ORDER BY bill_id))        FROM processed.billing t
UNION ALL SELECT 'payments',     md5(string_agg(t::text, '|' ORDER BY payment_id))     FROM processed.payments t
ORDER BY 1;

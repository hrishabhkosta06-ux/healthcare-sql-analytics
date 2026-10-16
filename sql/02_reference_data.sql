/* =============================================================================
   02_reference_data.sql   (Phase 1 reference data + Phase 2 workforce)
   Generates: raw.facilities, raw.departments, raw.procedures, raw.doctors
   Also defines read-only generator views (no data tables):
     gen.v_procedure_catalogue, gen.v_dept_params,
     gen.v_facility_params,     gen.v_doctor_weight
   All names are synthetic. No value is calibrated to Apollo.
   Prerequisite: 01_schema.sql. Session setting: SET apollo.seed = '20250331';
   ========================================================================== */

-- Helper: pick one element of a text array deterministically
CREATE OR REPLACE FUNCTION gen.pick(p_key text, p_arr text[])
RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT p_arr[1 + floor(gen.u(p_key) * array_length(p_arr, 1))::int]
$$;

-- Synthetic name lists (generic Indian names; no real-person sourcing)
CREATE OR REPLACE FUNCTION gen.first_name(p_key text, p_gender text)
RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_gender = 'Male' OR (p_gender = 'Other' AND gen.u(p_key || ':g') < 0.5) THEN
            gen.pick(p_key, ARRAY['Aarav','Aditya','Akash','Amit','Anil','Arjun','Ashok','Deepak',
                'Dev','Gaurav','Harish','Imran','Karan','Kunal','Manish','Mohan','Naveen','Nikhil',
                'Pranav','Rahul','Rajesh','Ravi','Rohan','Sachin','Sameer','Sanjay','Siddharth',
                'Sunil','Suresh','Tarun','Varun','Vijay','Vikram','Vinod','Yash','Faisal','Joseph',
                'Harpreet','Abhishek','Kiran'])
        ELSE
            gen.pick(p_key, ARRAY['Aditi','Aisha','Ananya','Anjali','Bhavna','Deepa','Divya','Fatima',
                'Gayatri','Isha','Jyoti','Kavita','Lakshmi','Meera','Megha','Neha','Nisha','Pooja',
                'Priya','Radha','Rekha','Ritu','Sakshi','Sana','Shalini','Shreya','Simran','Sneha',
                'Sunita','Swati','Tanvi','Usha','Vandana','Vidya','Zoya','Mary','Harleen','Komal',
                'Pallavi','Nandini'])
    END
$$;

CREATE OR REPLACE FUNCTION gen.last_name(p_key text)
RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT gen.pick(p_key, ARRAY['Sharma','Verma','Gupta','Singh','Kumar','Patel','Shah','Mehta',
        'Joshi','Iyer','Nair','Menon','Reddy','Rao','Naidu','Pillai','Das','Bose','Banerjee',
        'Chatterjee','Mukherjee','Ghosh','Sen','Khan','Ansari','Qureshi','Siddiqui','Dsouza',
        'Fernandes','Pereira','Kulkarni','Deshpande','Patil','Jadhav','Pawar','Chauhan','Rathore',
        'Yadav','Mishra','Pandey','Tiwari','Dubey','Saxena','Agarwal','Bansal','Malhotra',
        'Kapoor','Khanna','Gill','Sandhu'])
$$;

/* ---------------------------------------------------------------------------
   1. FACILITIES  (5 synthetic facilities; scaled simulated bed capacity, D-01)
   Bed counts are FIXED design parameters (10-25 per facility, 69 in total) so
   that capacity - and therefore IP volume - stays inside the target ranges
   for any seed. Set once, before any analytical result is produced
   (see documentation/generation_assumptions.md §4).
   Bed capacity is a synthetic simulation parameter calibrated for analytical
   coherence with the generated dataset volume. It does not represent actual
   Apollo Hospitals facility capacity.
   ------------------------------------------------------------------------ */
INSERT INTO raw.facilities
SELECT 'FAC' || lpad(f.n::text, 3, '0'),
       'Simulated Hospital ' || f.letter || ' (' || f.city || ')',
       f.city,
       f.tier,
       f.beds,
       DATE '2005-01-01' + gen.ri('fac:open:' || f.n, 0, 5800)
FROM (VALUES (1,'A','Mumbai',   'Metro',     18),
             (2,'B','Bengaluru','Metro',     15),
             (3,'C','Delhi',    'Metro',     15),
             (4,'D','Jaipur',   'Non-metro', 10),
             (5,'E','Lucknow',  'Non-metro', 11)) AS f(n, letter, city, tier, beds);

/* ---------------------------------------------------------------------------
   2. DEPARTMENTS (14 generic specialties; names not derived from Apollo mix)
   ------------------------------------------------------------------------ */
INSERT INTO raw.departments VALUES
 ('DEP01','Emergency Medicine','Emergency'),
 ('DEP02','General Medicine','Medical'),
 ('DEP03','Cardiology','Medical'),
 ('DEP04','Cardiothoracic Surgery','Surgical'),
 ('DEP05','Orthopaedics','Surgical'),
 ('DEP06','Neurology','Medical'),
 ('DEP07','Neurosurgery','Surgical'),
 ('DEP08','Oncology','Medical'),
 ('DEP09','Gastroenterology','Medical'),
 ('DEP10','General Surgery','Surgical'),
 ('DEP11','Obstetrics & Gynaecology','Surgical'),
 ('DEP12','Paediatrics','Medical'),
 ('DEP13','Nephrology','Medical'),
 ('DEP14','Radiology & Imaging','Diagnostic');

/* ---------------------------------------------------------------------------
   3. PROCEDURE CATALOGUE (view) + PROCEDURES (table)
   Care-setting flags (op/ip/dc/er) are generator configuration only; they are
   NOT a column of the procedures table. Price ranges (INR) are
   portfolio assumptions (A-08), not sourced tariffs.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW gen.v_procedure_catalogue AS
SELECT * FROM (VALUES
 ( 1,'Emergency Wound Suturing'       ,'DEP01','Minor Procedure',   1500,   4000, false,false,false,true ),
 ( 2,'ECG and Cardiac Monitoring'     ,'DEP01','Diagnostic',         800,   2500, false,false,false,true ),
 ( 3,'Fracture Splinting and Reduction','DEP01','Minor Procedure',  3000,   9000, false,false,false,true ),
 ( 4,'Comprehensive Health Assessment','DEP02','Diagnostic',        2500,   8000, true ,false,false,false),
 ( 5,'IV Fluid and Infusion Therapy'  ,'DEP02','Therapy Session',   1500,   5000, false,true ,true ,false),
 ( 6,'Nebulisation Therapy'           ,'DEP02','Therapy Session',    500,   1500, true ,true ,false,false),
 ( 7,'Echocardiography'               ,'DEP03','Diagnostic',        2500,   6000, true ,true ,false,false),
 ( 8,'Treadmill Stress Test'          ,'DEP03','Diagnostic',        2000,   5000, true ,false,false,false),
 ( 9,'Coronary Angiography'           ,'DEP03','Interventional',   15000,  40000, false,true ,true ,false),
 (10,'Coronary Angioplasty (PTCA)'    ,'DEP03','Interventional',  150000, 350000, false,true ,false,false),
 (11,'Pacemaker Implantation'         ,'DEP03','Interventional',  200000, 450000, false,true ,false,false),
 (12,'Coronary Artery Bypass Grafting','DEP04','Major Surgery',   250000, 550000, false,true ,false,false),
 (13,'Heart Valve Replacement'        ,'DEP04','Major Surgery',   300000, 600000, false,true ,false,false),
 (14,'Vascular Bypass Surgery'        ,'DEP04','Major Surgery',   150000, 350000, false,true ,false,false),
 (15,'Varicose Vein Ablation'         ,'DEP04','Interventional',   40000,  90000, false,true ,true ,false),
 (16,'Total Knee Replacement'         ,'DEP05','Major Surgery',   180000, 350000, false,true ,false,false),
 (17,'Total Hip Replacement'          ,'DEP05','Major Surgery',   200000, 400000, false,true ,false,false),
 (18,'Arthroscopic Knee Surgery'      ,'DEP05','Major Surgery',    80000, 180000, false,true ,true ,false),
 (19,'Fracture Fixation (ORIF)'       ,'DEP05','Major Surgery',    70000, 200000, false,true ,false,false),
 (20,'Joint Injection'                ,'DEP05','Minor Procedure',   2000,   6000, true ,false,false,false),
 (21,'Physiotherapy Session'          ,'DEP05','Therapy Session',    800,   2000, true ,true ,false,false),
 (22,'Electroencephalogram (EEG)'     ,'DEP06','Diagnostic',        2000,   5000, true ,true ,false,false),
 (23,'Nerve Conduction Study'         ,'DEP06','Diagnostic',        2500,   6000, true ,false,false,false),
 (24,'Lumbar Puncture'                ,'DEP06','Minor Procedure',   3000,   8000, false,true ,false,false),
 (25,'Craniotomy'                     ,'DEP07','Major Surgery',   250000, 550000, false,true ,false,false),
 (26,'Spinal Decompression Surgery'   ,'DEP07','Major Surgery',   180000, 400000, false,true ,false,false),
 (27,'Lumbar Discectomy'              ,'DEP07','Major Surgery',   120000, 280000, false,true ,false,false),
 (28,'Chemotherapy Cycle'             ,'DEP08','Therapy Session',  25000,  90000, false,true ,true ,false),
 (29,'Radiotherapy Session'           ,'DEP08','Therapy Session',  15000,  40000, false,false,true ,false),
 (30,'Tumour Biopsy'                  ,'DEP08','Minor Procedure',   8000,  25000, true ,true ,true ,false),
 (31,'PET-CT Scan'                    ,'DEP08','Diagnostic',       18000,  30000, true ,true ,false,false),
 (32,'Upper GI Endoscopy'             ,'DEP09','Diagnostic',        4000,  10000, true ,true ,true ,false),
 (33,'Colonoscopy'                    ,'DEP09','Diagnostic',        6000,  15000, false,true ,true ,false),
 (34,'ERCP'                           ,'DEP09','Interventional',   40000,  90000, false,true ,false,false),
 (35,'Laparoscopic Cholecystectomy'   ,'DEP10','Major Surgery',    70000, 150000, false,true ,false,false),
 (36,'Hernia Repair'                  ,'DEP10','Major Surgery',    60000, 130000, false,true ,true ,false),
 (37,'Appendicectomy'                 ,'DEP10','Major Surgery',    50000, 120000, false,true ,false,false),
 (38,'Excision of Lump'               ,'DEP10','Minor Procedure',   5000,  20000, true ,false,true ,false),
 (39,'Wound Debridement'              ,'DEP10','Minor Procedure',   3000,  12000, true ,true ,true ,false),
 (40,'Normal Delivery'                ,'DEP11','Major Surgery',    35000,  80000, false,true ,false,false),
 (41,'Caesarean Section'              ,'DEP11','Major Surgery',    70000, 150000, false,true ,false,false),
 (42,'Hysterectomy'                   ,'DEP11','Major Surgery',    90000, 200000, false,true ,false,false),
 (43,'Obstetric Ultrasound'           ,'DEP11','Diagnostic',        1500,   4000, true ,false,false,false),
 (44,'Hysteroscopy'                   ,'DEP11','Minor Procedure',  15000,  35000, false,false,true ,false),
 (45,'Neonatal Phototherapy'          ,'DEP12','Therapy Session',   3000,   8000, false,true ,false,false),
 (46,'Paediatric Nebulisation'        ,'DEP12','Therapy Session',    500,   1500, true ,true ,false,false),
 (47,'Paediatric IV Therapy'          ,'DEP12','Therapy Session',   1500,   4000, false,true ,false,false),
 (48,'Childhood Immunisation'         ,'DEP12','Minor Procedure',    500,   3000, true ,false,false,false),
 (49,'Haemodialysis Session'          ,'DEP13','Therapy Session',   2500,   6000, false,true ,true ,false),
 (50,'Renal Biopsy'                   ,'DEP13','Minor Procedure',  15000,  35000, false,true ,true ,false),
 (51,'AV Fistula Creation'            ,'DEP13','Interventional',   30000,  70000, false,true ,true ,false),
 (52,'Kidney Function Panel'          ,'DEP13','Diagnostic',        1000,   3000, true ,false,false,false),
 (53,'MRI Brain'                      ,'DEP14','Diagnostic',        6000,  15000, true ,false,false,false),
 (54,'CT Abdomen'                     ,'DEP14','Diagnostic',        4000,  10000, true ,false,false,false),
 (55,'X-Ray Chest'                    ,'DEP14','Diagnostic',         400,   1200, true ,false,false,false),
 (56,'Ultrasound Abdomen'             ,'DEP14','Diagnostic',        1200,   3500, true ,false,false,false),
 (57,'MRI Spine'                      ,'DEP14','Diagnostic',        7000,  16000, true ,false,false,false)
) AS c(n, procedure_name, department_id, procedure_category, price_lo, price_hi, op, ip, dc, er);

INSERT INTO raw.procedures
SELECT 'PRC' || lpad(c.n::text, 3, '0'),
       c.procedure_name,
       c.department_id,
       c.procedure_category,
       round((c.price_lo + gen.u('proc:price:' || c.n) * (c.price_hi - c.price_lo)) / 100.0) * 100
FROM gen.v_procedure_catalogue c;

/* ---------------------------------------------------------------------------
   4. GENERATOR PARAMETER VIEWS (read-only, deterministic)
   Department weights: category base x random perturbation (+/-20%).
   No department is hand-picked to lead (A-04).
   ------------------------------------------------------------------------ */
CREATE OR REPLACE VIEW gen.v_dept_params AS
SELECT d.department_id,
       d.department_category,
       -- OP demand weight (Emergency has no OP appointments)
       CASE d.department_category WHEN 'Medical'    THEN 1.0
                                  WHEN 'Surgical'   THEN 0.8
                                  WHEN 'Diagnostic' THEN 0.6
                                  ELSE 0 END
         * gen.ur('dept:opw:' || d.department_id, 0.8, 1.2)              AS op_weight,
       -- IP demand weight (Emergency and Radiology do not admit)
       CASE WHEN d.department_category IN ('Medical','Surgical') THEN 1.0 ELSE 0 END
         * gen.ur('dept:ipw:' || d.department_id, 0.8, 1.2)              AS ip_weight,
       -- Mean LOS by category band (A-19)
       CASE WHEN d.department_category = 'Surgical'
            THEN gen.ur('dept:los:' || d.department_id, 4.5, 8.5)
            ELSE gen.ur('dept:los:' || d.department_id, 3.5, 6.5) END      AS los_mean,
       EXISTS (SELECT 1 FROM gen.v_procedure_catalogue c
               WHERE c.department_id = d.department_id AND c.dc)          AS dc_capable,
       -- Structural eligibility rules (see documentation/data_dictionary.md)
       d.department_id = 'DEP12'                                          AS minors_only,
       d.department_id = 'DEP11'                                          AS female_18_50_only
FROM raw.departments d;

-- Facility parameters: home-facility weight, bed-turnover idle gap (drives
-- occupancy, A-18; identical for every facility so facility differences come
-- from department mix and LOS, not from a facility-specific setting),
-- room rate (A-11), ER fee (A-10)
CREATE OR REPLACE VIEW gen.v_facility_params AS
SELECT f.facility_id,
       f.city_tier,
       f.operating_bed_count,
       CASE WHEN f.city_tier = 'Metro' THEN 0.24 ELSE 0.14 END            AS home_weight,
       2.6::double precision                                              AS bed_gap_mean_days,  -- same for all facilities
       CASE WHEN f.city_tier = 'Metro'
            THEN round(gen.ur('fac:room:' || f.facility_id, 6000, 12000)::numeric / 100) * 100
            ELSE round(gen.ur('fac:room:' || f.facility_id, 3000,  6000)::numeric / 100) * 100
       END                                                               AS room_rate_per_day,
       CASE WHEN f.city_tier = 'Metro' THEN 1200 ELSE 900 END::numeric    AS er_fee
FROM raw.facilities f;

/* ---------------------------------------------------------------------------
   5. DOCTORS (Phase 2)
   Every available facility-department combination gets one "founding" doctor
   who joined before the window. 12 additional doctors are placed on combos
   chosen by hash rank (not hand-picked); half join inside the window.
   Non-metro facilities offer 9 of 14 departments.
   ------------------------------------------------------------------------ */
WITH combos AS (
    SELECT f.facility_id, d.department_id, f.city_tier
    FROM raw.facilities f
    CROSS JOIN raw.departments d
    WHERE f.city_tier = 'Metro'
       OR d.department_id IN ('DEP01','DEP02','DEP03','DEP05','DEP10',
                              'DEP11','DEP12','DEP13','DEP14')
),
extra AS (
    SELECT facility_id, department_id
    FROM combos
    ORDER BY gen.u('doc:extra:' || facility_id || department_id), facility_id, department_id
    LIMIT 12
),
roster AS (
    SELECT c.facility_id, c.department_id, c.city_tier, 1 AS slot FROM combos c
    UNION ALL
    SELECT e.facility_id, e.department_id, c.city_tier, 2
    FROM extra e JOIN combos c USING (facility_id, department_id)
),
numbered AS (
    SELECT r.*,
           row_number() OVER (ORDER BY r.facility_id, r.department_id, r.slot) AS n
    FROM roster r
),
attrs AS (
    SELECT n.*,
           CASE WHEN gen.u('doc:sex:' || n.n) < 0.5 THEN 'Male' ELSE 'Female' END AS sex,
           CASE WHEN gen.u('doc:des:' || n.n) < 0.30 THEN 'Associate Consultant'
                WHEN gen.u('doc:des:' || n.n) < 0.75 THEN 'Consultant'
                ELSE 'Senior Consultant' END                                       AS designation
    FROM numbered n
)
INSERT INTO raw.doctors
SELECT 'DOC' || lpad(a.n::text, 3, '0'),
       'Dr. ' || gen.first_name('doc:fn:' || a.n, a.sex) || ' ' || gen.last_name('doc:ln:' || a.n),
       a.department_id,
       a.facility_id,
       a.designation,
       CASE a.designation WHEN 'Associate Consultant' THEN gen.ri('doc:yrs:' || a.n, 2, 8)
                          WHEN 'Consultant'           THEN gen.ri('doc:yrs:' || a.n, 6, 18)
                          ELSE                             gen.ri('doc:yrs:' || a.n, 15, 35) END,
       round( CASE a.designation WHEN 'Associate Consultant' THEN 600
                                 WHEN 'Consultant'           THEN 1000
                                 ELSE 1500 END
              * gen.ur('doc:fee:' || a.n, 0.85, 1.15)
              * CASE WHEN a.city_tier = 'Metro' THEN 1.0 ELSE 0.8 END / 50.0) * 50,
       CASE WHEN a.slot = 2 AND gen.u('doc:joinwin:' || a.n) < 0.5
            THEN DATE '2023-04-01' + gen.ri('doc:join:' || a.n, 0, 540)       -- joins in window
            ELSE DATE '2008-01-01' + gen.ri('doc:join:' || a.n, 0, 5568)      -- joined before window
       END
FROM attrs a;

-- Doctor productivity weight (lognormal); workload emerges from weighted draws (A-06)
CREATE OR REPLACE VIEW gen.v_doctor_weight AS
SELECT d.doctor_id, d.facility_id, d.department_id, d.join_date,
       exp(0.35 * gen.normal('doc:w:' || d.doctor_id)) AS weight
FROM raw.doctors d;

-- Phase 1-2 row counts
SELECT 'facilities' AS tbl, count(*) FROM raw.facilities
UNION ALL SELECT 'departments', count(*) FROM raw.departments
UNION ALL SELECT 'procedures',  count(*) FROM raw.procedures
UNION ALL SELECT 'doctors',     count(*) FROM raw.doctors
UNION ALL SELECT 'total_operating_beds', sum(operating_bed_count) FROM raw.facilities;

/* ---------------------------------------------------------------------------
   6. STRUCTURAL ELIGIBILITY RULE (see documentation/data_dictionary.md), used by 04 and 05
   Paediatrics: age < 18 on the event date.
   Obstetrics & Gynaecology: female, age 18-50 on the event date.
   Minors may otherwise only be seen in Emergency Medicine and Radiology.
   ------------------------------------------------------------------------ */
CREATE OR REPLACE FUNCTION gen.dept_eligible(p_dept text, p_dob date, p_gender text, p_on date)
RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_dept = 'DEP12' THEN date_part('year', age(p_on, p_dob)) < 18
        WHEN p_dept = 'DEP11' THEN p_gender = 'Female'
                               AND date_part('year', age(p_on, p_dob)) BETWEEN 18 AND 50
        WHEN p_dept IN ('DEP01','DEP14') THEN true
        ELSE date_part('year', age(p_on, p_dob)) >= 18
    END
$$;

-- Facility-department availability = combinations that have a doctor
CREATE OR REPLACE VIEW gen.v_available_dept AS
SELECT DISTINCT facility_id, department_id FROM raw.doctors;

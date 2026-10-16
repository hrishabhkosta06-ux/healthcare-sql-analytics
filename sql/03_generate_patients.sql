/* =============================================================================
   03_generate_patients.sql   (Phase 3)
   Generates candidate patients into raw.patients.

   registration_date is written here as a PROVISIONAL "anchor" (planned first
   contact). After all encounters exist, 05_generate_visits.sql resets it to the
   actual first contact (earliest booking date or visit date) and removes
   candidates that never had any contact (rule: registration = first contact).

   DOB rule: DOB <= anchor - 120 days, which guarantees DOB < registration even
   when a booking precedes the anchor (max lead time 60 days).
   ========================================================================== */

WITH cities AS (            -- city -> state lookup for patient residence
    SELECT * FROM (VALUES
        ('Mumbai','Maharashtra'), ('Bengaluru','Karnataka'), ('Delhi','Delhi'),
        ('Jaipur','Rajasthan'),   ('Lucknow','Uttar Pradesh'), ('Pune','Maharashtra'),
        ('Thane','Maharashtra'),  ('Mysuru','Karnataka'),   ('Noida','Uttar Pradesh'),
        ('Gurugram','Haryana'),   ('Kanpur','Uttar Pradesh'), ('Ajmer','Rajasthan'),
        ('Nashik','Maharashtra'), ('Faridabad','Haryana'),  ('Udaipur','Rajasthan')
    ) AS c(city, state)
),
other_cities AS (
    SELECT city, state, row_number() OVER (ORDER BY city) AS rn, count(*) OVER () AS cnt
    FROM cities
),
home_fac AS (               -- cumulative home-facility weights for inverse-CDF pick
    SELECT facility_id, city_tier,
           sum(home_weight) OVER (ORDER BY facility_id) - home_weight AS cum_lo,
           sum(home_weight) OVER (ORDER BY facility_id)               AS cum_hi
    FROM gen.v_facility_params
),
base AS (
    SELECT g.n,
           p.window_start + gen.ri('pat:anchor:' || g.n, 0, 730)           AS anchor,
           CASE WHEN gen.u('pat:sex:' || g.n) < 0.49 THEN 'Male'
                WHEN gen.u('pat:sex:' || g.n) < 0.99 THEN 'Female'
                ELSE 'Other' END                                           AS gender,
           CASE WHEN gen.u('pat:minor:' || g.n) < p.minor_share
                THEN gen.ri('pat:age:' || g.n, 0, 17)
                ELSE 18 + floor(72 * power(gen.u('pat:age:' || g.n), 1.3))::int
           END                                                             AS age_at_anchor,
           gen.u('pat:home:' || g.n)                                       AS u_home
    FROM gen.v_params p
    CROSS JOIN LATERAL generate_series(1, p.candidate_patients) AS g(n)
),
placed AS (
    SELECT b.*, h.facility_id AS home_facility,
           f.city AS facility_city
    FROM base b
    JOIN home_fac h ON b.u_home >= h.cum_lo AND b.u_home < h.cum_hi
    JOIN raw.facilities f ON f.facility_id = h.facility_id
),
resident AS (
    SELECT pl.*,
           CASE WHEN gen.u('pat:cityhome:' || pl.n) < 0.85
                THEN pl.facility_city
                ELSE (SELECT oc.city FROM other_cities oc
                      WHERE oc.rn = 1 + floor(gen.u('pat:city:' || pl.n) * oc.cnt)::int)
           END AS city
    FROM placed pl
),
final AS (
    SELECT r.*,
           row_number() OVER (ORDER BY r.anchor, r.n) AS id_seq
    FROM resident r
)
INSERT INTO raw.patients
SELECT 'PAT' || lpad(fi.id_seq::text, 5, '0'),
       gen.first_name('pat:fn:' || fi.n, fi.gender) || ' ' || gen.last_name('pat:ln:' || fi.n),
       fi.gender,
       fi.anchor - (120 + floor(fi.age_at_anchor * 365.25
                                + gen.u('pat:dob:' || fi.n) * 245))::int,
       fi.city,
       c.state,
       fi.anchor,                       -- provisional; finalised in 05
       fi.home_facility                 -- provisional; finalised in 05
FROM final fi
JOIN cities c ON c.city = fi.city;

SELECT count(*) AS candidate_patients,
       min(registration_date) AS min_anchor,
       max(registration_date) AS max_anchor,
       count(*) FILTER (WHERE date_of_birth >= registration_date) AS dob_violations
FROM raw.patients;

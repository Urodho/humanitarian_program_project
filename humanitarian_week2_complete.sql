/*
WEEK 2 — ADVANCED HUMANITARIAN PROGRAMME ANALYSIS
MySQL 8.0+

Use the EXISTING Week 1 database. This script does NOT create/reset the
programme database, base tables, or sample data. It creates reporting views,
a requested insert-log table, triggers, and stored procedures.

Schema assumptions from the Week 1 file:
  1. beneficiary_type is 'Individuals' or 'Households'. A household is
     converted to 6 individuals, matching Week 1.
  2. jurisdiction_hierarchy uses the direct chain Region -> District -> Village,
     with type values exactly 'Region', 'District', and 'Village'.
  3. Each village maps to one district and each district maps to one region.
  4. Reach is the sum of partner-reported beneficiaries converted to individuals;
     there is no person-level ID with which to deduplicate overlap across partners.
  5. Coverage is total individual beneficiaries / population * 100.
*/

USE humanitarian_program;

-- Confirm the MySQL table-name case behavior before creating the requested views.
SELECT VERSION() AS mysql_version, @@lower_case_table_names AS lower_case_table_names;

/* Reusable row-level views used by later tasks. */
CREATE OR REPLACE VIEW vw_humanitarian_individual_reach AS
SELECT
    partner_id,
    partner,
    village,
    beneficiaries,
    beneficiary_type,
    CASE
        WHEN beneficiary_type = 'Individuals' THEN beneficiaries
        WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
        ELSE NULL
    END AS individual_beneficiaries
FROM beneficiary_partner_data;

/* One row per village-to-district mapping, with its population and region.
   DISTINCT protects against duplicate identical hierarchy links. */
CREATE OR REPLACE VIEW vw_humanitarian_village_district AS
SELECT DISTINCT
    v.village_id,
    v.village,
    v.total_population,
    r.id AS region_id,
    r.name AS region,
    d.id AS district_id,
    d.name AS district
FROM village_locations AS v
INNER JOIN jurisdiction_hierarchy AS village_h
    ON village_h.name = v.village
   AND village_h.type = 'Village'
INNER JOIN jurisdiction_hierarchy AS d
    ON d.id = village_h.parent_id
   AND d.type = 'District'
INNER JOIN jurisdiction_hierarchy AS r
    ON r.id = d.parent_id
   AND r.type = 'Region';

/* ================================================================
   TASK 1 — ADVANCED AGGREGATION
   ================================================================ */

-- 1. Partners with more than 5,000 individual beneficiaries.
SELECT
    b.partner,
    SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) AS total_individual_beneficiaries
FROM beneficiary_partner_data AS b
GROUP BY b.partner
HAVING SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) > 5000
ORDER BY total_individual_beneficiaries DESC;

-- 2. Villages served by more than one distinct partner.
SELECT
    b.village,
    COUNT(DISTINCT b.partner) AS number_of_partners,
    SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) AS total_individual_beneficiaries
FROM beneficiary_partner_data AS b
GROUP BY b.village
HAVING COUNT(DISTINCT b.partner) > 1
ORDER BY number_of_partners DESC, b.village;

-- 3. Partners operating in more than 3 distinct villages.
SELECT
    b.partner,
    COUNT(DISTINCT b.village) AS villages_served,
    SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) AS total_individual_beneficiaries
FROM beneficiary_partner_data AS b
GROUP BY b.partner
HAVING COUNT(DISTINCT b.village) > 3
ORDER BY villages_served DESC, total_individual_beneficiaries DESC;

-- 4. Districts with more than 10,000 individual beneficiaries.
SELECT
    d.id AS district_id,
    d.name AS district,
    COUNT(DISTINCT b.village) AS villages_with_partner_records,
    SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) AS total_individual_beneficiaries
FROM beneficiary_partner_data AS b
INNER JOIN jurisdiction_hierarchy AS village_h
    ON village_h.name = b.village
   AND village_h.type = 'Village'
INNER JOIN jurisdiction_hierarchy AS d
    ON d.id = village_h.parent_id
   AND d.type = 'District'
GROUP BY d.id, d.name
HAVING SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) > 10000
ORDER BY total_individual_beneficiaries DESC;

/* ================================================================
   TASK 2 — UNION ALL: ALL VILLAGES AND THEIR PARTNER ACTIVITY
   ================================================================ */
WITH village_partner_activity AS (
    SELECT
        r.village,
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_individual_reach AS r
    GROUP BY r.village, r.partner
)
SELECT
    v.village,
    a.partner,
    a.total_individual_beneficiaries,
    'Partner activity recorded' AS activity_status
FROM village_locations AS v
INNER JOIN village_partner_activity AS a
    ON a.village = v.village

UNION ALL

SELECT
    v.village,
    NULL AS partner,
    NULL AS total_individual_beneficiaries,
    'No recorded partner activity' AS activity_status
FROM village_locations AS v
WHERE NOT EXISTS (
    SELECT 1
    FROM beneficiary_partner_data AS b
    WHERE b.village = v.village
)
ORDER BY village, partner;

/* ================================================================
   TASK 3 — NESTED QUERIES / SUBQUERIES
   ================================================================ */

-- 3A. Village coverage above the average across all villages.
-- Villages without partner records count as 0% coverage in the average.
WITH village_coverage AS (
    SELECT
        v.village,
        v.total_population AS population,
        COALESCE(SUM(r.individual_beneficiaries), 0) AS beneficiaries,
        100.0 * COALESCE(SUM(r.individual_beneficiaries), 0)
            / NULLIF(v.total_population, 0) AS coverage
    FROM village_locations AS v
    LEFT JOIN vw_humanitarian_individual_reach AS r
        ON r.village = v.village
    GROUP BY v.village, v.total_population
)
SELECT
    vc.village,
    vc.population,
    vc.beneficiaries,
    ROUND(vc.coverage, 2) AS coverage_percentage
FROM village_coverage AS vc
WHERE vc.coverage > (
    SELECT AVG(vc_average.coverage)
    FROM village_coverage AS vc_average
)
ORDER BY vc.coverage DESC, vc.village;

-- 3B. Partners above the average partner total, using derived-table subqueries.
SELECT
    partner_totals.partner,
    partner_totals.total_individual_beneficiaries
FROM (
    SELECT
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_individual_reach AS r
    GROUP BY r.partner
) AS partner_totals
WHERE partner_totals.total_individual_beneficiaries > (
    SELECT AVG(average_totals.total_individual_beneficiaries)
    FROM (
        SELECT
            r2.partner,
            SUM(r2.individual_beneficiaries) AS total_individual_beneficiaries
        FROM vw_humanitarian_individual_reach AS r2
        GROUP BY r2.partner
    ) AS average_totals
)
ORDER BY partner_totals.total_individual_beneficiaries DESC;

/* ================================================================
   TASK 4 — DISTRICT CTE ANALYSIS

   IMPORTANT: district_population is calculated from the village mapping alone.
   It is aggregated BEFORE it is joined to partner reach, so a village's
   population is not repeated once per partner/beneficiary record.
   ================================================================ */
WITH district_population AS (
    SELECT
        vd.region_id,
        vd.region,
        vd.district_id,
        vd.district,
        SUM(vd.total_population) AS district_population
    FROM vw_humanitarian_village_district AS vd
    GROUP BY vd.region_id, vd.region, vd.district_id, vd.district
),
district_reach AS (
    SELECT
        vd.region_id,
        vd.district_id,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries,
        COUNT(DISTINCT r.partner) AS number_of_partners
    FROM vw_humanitarian_village_district AS vd
    INNER JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY vd.region_id, vd.district_id
),
district_report AS (
    SELECT
        dp.region_id,
        dp.region,
        dp.district_id,
        dp.district,
        dp.district_population,
        COALESCE(dr.total_individual_beneficiaries, 0)
            AS total_individual_beneficiaries,
        COALESCE(dr.number_of_partners, 0) AS number_of_partners
    FROM district_population AS dp
    LEFT JOIN district_reach AS dr
        ON dr.region_id = dp.region_id
       AND dr.district_id = dp.district_id
)
SELECT
    region,
    district,
    total_individual_beneficiaries,
    district_population,
    ROUND(
        100.0 * total_individual_beneficiaries
            / NULLIF(district_population, 0),
        2
    ) AS coverage,
    number_of_partners
FROM district_report
ORDER BY region, district;

/* ================================================================
   TASK 5 — WINDOW FUNCTIONS
   ================================================================ */

-- 5A. Rank partners by total individual beneficiaries. Ties share a rank.
WITH partner_totals AS (
    SELECT
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_individual_reach AS r
    GROUP BY r.partner
)
SELECT
    partner,
    total_individual_beneficiaries,
    RANK() OVER (
        ORDER BY total_individual_beneficiaries DESC
    ) AS partner_rank
FROM partner_totals
ORDER BY partner_rank, partner;

-- 5B. Rank districts within each region by individual beneficiaries.
-- All mapped districts are retained; districts without activity rank at 0 reach.
WITH district_totals AS (
    SELECT
        vd.region_id,
        vd.region,
        vd.district_id,
        vd.district,
        COALESCE(SUM(r.individual_beneficiaries), 0)
            AS total_individual_beneficiaries
    FROM vw_humanitarian_village_district AS vd
    LEFT JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY vd.region_id, vd.region, vd.district_id, vd.district
)
SELECT
    region,
    district,
    total_individual_beneficiaries,
    RANK() OVER (
        PARTITION BY region_id
        ORDER BY total_individual_beneficiaries DESC
    ) AS district_rank_within_region
FROM district_totals
ORDER BY region, district_rank_within_region, district;

-- 5C. One top partner per district. ROW_NUMBER breaks ties by partner name.
WITH partner_district_totals AS (
    SELECT
        vd.region_id,
        vd.region,
        vd.district_id,
        vd.district,
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_village_district AS vd
    INNER JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY
        vd.region_id, vd.region, vd.district_id, vd.district, r.partner
),
ranked_partner_districts AS (
    SELECT
        pdt.*,
        ROW_NUMBER() OVER (
            PARTITION BY district_id
            ORDER BY total_individual_beneficiaries DESC, partner ASC
        ) AS row_num
    FROM partner_district_totals AS pdt
)
SELECT
    region,
    district,
    partner,
    total_individual_beneficiaries
FROM ranked_partner_districts
WHERE row_num = 1
ORDER BY region, district;

/* ================================================================
   TASK 6 — REUSABLE SUMMARY VIEWS

   Week 1 also creates BASE TABLES named Partner_summary and District_summary.
   On MySQL installations with case-insensitive table names, those tables can
   conflict with these requested lowercase view names. Check the query below.
   If a conflict exists, preserve (do not drop) the old snapshots by renaming
   them once before running the two CREATE VIEW statements, for example:
       RENAME TABLE Partner_summary TO week1_partner_summary_snapshot;
       RENAME TABLE District_summary TO week1_district_summary_snapshot;
   Only run a RENAME for a table that exists and only if the target name is free.
   ================================================================ */
SELECT TABLE_NAME, TABLE_TYPE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND LOWER(TABLE_NAME) IN ('district_summary', 'partner_summary');

-- 6A. District reporting view. Population is aggregated separately from reach.
DROP TABLE IF EXISTS district_summary;
DROP TABLE IF EXISTS partner_summary;
CREATE OR REPLACE VIEW district_summary AS
SELECT
    dp.region,
    dp.district,
    dp.district_population,
    COALESCE(dr.total_individual_beneficiaries, 0)
        AS total_individual_beneficiaries,
    ROUND(
        100.0 * COALESCE(dr.total_individual_beneficiaries, 0)
            / NULLIF(dp.district_population, 0),
        2
    ) AS coverage,
    COALESCE(dr.number_of_partners, 0) AS number_of_partners
FROM (
    SELECT
        vd.region_id,
        vd.region,
        vd.district_id,
        vd.district,
        SUM(vd.total_population) AS district_population
    FROM vw_humanitarian_village_district AS vd
    GROUP BY vd.region_id, vd.region, vd.district_id, vd.district
) AS dp
LEFT JOIN (
    SELECT
        vd.region_id,
        vd.district_id,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries,
        COUNT(DISTINCT r.partner) AS number_of_partners
    FROM vw_humanitarian_village_district AS vd
    INNER JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY vd.region_id, vd.district_id
) AS dr
    ON dr.region_id = dp.region_id
   AND dr.district_id = dp.district_id;

-- 6B. Partner reporting view.
-- Reach/villages are summarized independently from district mapping to avoid
-- multiplying a partner's reach if a hierarchy mapping is duplicated.
CREATE OR REPLACE VIEW partner_summary AS
SELECT
    pr.partner,
    pr.total_individual_beneficiaries,
    pr.villages_served,
    COALESCE(pd.districts_reached, 0) AS districts_reached
FROM (
    SELECT
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries,
        COUNT(DISTINCT r.village) AS villages_served
    FROM vw_humanitarian_individual_reach AS r
    GROUP BY r.partner
) AS pr
LEFT JOIN (
    SELECT
        r.partner,
        COUNT(DISTINCT vd.district_id) AS districts_reached
    FROM vw_humanitarian_individual_reach AS r
    INNER JOIN vw_humanitarian_village_district AS vd
        ON vd.village = r.village
    GROUP BY r.partner
) AS pd
    ON pd.partner = pr.partner;

/* ================================================================
   TASK 7 — TRIGGERS AND INSERT LOGGING
   ================================================================ */

-- Requested log table; IF NOT EXISTS avoids recreating it on reruns.
CREATE TABLE IF NOT EXISTS beneficiary_insert_log (
    log_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    partner_id INTEGER,
    partner VARCHAR(30) NOT NULL,
    village VARCHAR(30) NOT NULL,
    beneficiaries INTEGER NOT NULL,
    beneficiary_type VARCHAR(30) NOT NULL,
    inserted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- The Week 1 beneficiary table has no non-negative CHECK constraint.
DROP TRIGGER IF EXISTS trg_humanitarian_validate_beneficiary_bi;
DROP TRIGGER IF EXISTS trg_humanitarian_log_beneficiary_ai;

DELIMITER $$
CREATE TRIGGER trg_humanitarian_validate_beneficiary_bi
BEFORE INSERT ON beneficiary_partner_data
FOR EACH ROW
BEGIN
    IF NEW.beneficiaries < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Beneficiaries cannot be negative';
    END IF;
END$$

CREATE TRIGGER trg_humanitarian_log_beneficiary_ai
AFTER INSERT ON beneficiary_partner_data
FOR EACH ROW
BEGIN
    INSERT INTO beneficiary_insert_log
        (partner_id, partner, village, beneficiaries, beneficiary_type)
    VALUES
        (NEW.partner_id, NEW.partner, NEW.village,
         NEW.beneficiaries, NEW.beneficiary_type);
END$$
DELIMITER ;

/* ================================================================
   TASK 8 — STORED PROCEDURES
   ================================================================ */

DROP PROCEDURE IF EXISTS GetPartnerReport;
DROP PROCEDURE IF EXISTS GetDistrictImpact;

DELIMITER $$
CREATE PROCEDURE GetPartnerReport(IN p_partner_name VARCHAR(30))
BEGIN
    WITH ranked_partners AS (
        SELECT
            ps.partner,
            ps.total_individual_beneficiaries,
            ps.villages_served,
            ps.districts_reached,
            RANK() OVER (
                ORDER BY ps.total_individual_beneficiaries DESC
            ) AS partner_ranking
        FROM partner_summary AS ps
    )
    SELECT
        partner,
        total_individual_beneficiaries,
        villages_served,
        districts_reached,
        partner_ranking
    FROM ranked_partners
    WHERE partner = p_partner_name;
END$$

CREATE PROCEDURE GetDistrictImpact(IN p_district_name VARCHAR(50))
BEGIN
    SELECT
        region,
        district,
        district_population,
        total_individual_beneficiaries,
        coverage AS coverage_rate,
        number_of_partners
    FROM district_summary
    WHERE district = p_district_name;
END$$
DELIMITER ;

-- Example calls (replace the text with exact names in your database):
-- CALL GetPartnerReport('Partner Name');
-- CALL GetDistrictImpact('District Name');

/* ================================================================
   TASK 9 — ADVANCED CHALLENGES
   ================================================================ */

-- Challenge 1. Highest-beneficiary partner(s) in each district.
-- RANK returns all tied leaders.
WITH partner_district_totals AS (
    SELECT
        vd.region_id,
        vd.region,
        vd.district_id,
        vd.district,
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_village_district AS vd
    INNER JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY
        vd.region_id, vd.region, vd.district_id, vd.district, r.partner
),
ranked AS (
    SELECT
        pdt.*,
        RANK() OVER (
            PARTITION BY district_id
            ORDER BY total_individual_beneficiaries DESC
        ) AS district_partner_rank
    FROM partner_district_totals AS pdt
)
SELECT
    region,
    district,
    partner,
    total_individual_beneficiaries
FROM ranked
WHERE district_partner_rank = 1
ORDER BY region, district, partner;

-- Challenge 2. Districts whose coverage exceeds the average district coverage.
SELECT
    ds.region,
    ds.district,
    ds.district_population,
    ds.total_individual_beneficiaries,
    ds.coverage,
    ds.number_of_partners
FROM district_summary AS ds
WHERE ds.coverage > (
    SELECT AVG(ds_average.coverage)
    FROM district_summary AS ds_average
)
ORDER BY ds.coverage DESC, ds.region, ds.district;

-- Challenge 3. Partners who are a top (possibly tied) partner in at least one district.
WITH partner_district_totals AS (
    SELECT
        vd.district_id,
        vd.district,
        r.partner,
        SUM(r.individual_beneficiaries) AS total_individual_beneficiaries
    FROM vw_humanitarian_village_district AS vd
    INNER JOIN vw_humanitarian_individual_reach AS r
        ON r.village = vd.village
    GROUP BY vd.district_id, vd.district, r.partner
),
ranked AS (
    SELECT
        pdt.*,
        RANK() OVER (
            PARTITION BY district_id
            ORDER BY total_individual_beneficiaries DESC
        ) AS district_partner_rank
    FROM partner_district_totals AS pdt
)
SELECT
    partner,
    COUNT(DISTINCT district_id) AS districts_dominated,
    GROUP_CONCAT(DISTINCT district ORDER BY district SEPARATOR ', ')
        AS districts
FROM ranked
WHERE district_partner_rank = 1
GROUP BY partner
ORDER BY districts_dominated DESC, partner;

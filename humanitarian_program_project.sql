CREATE DATABASE humanitarian_program;
USE humanitarian_program;
/* =========================================================
   SAMPLE DATA INSERTION
   ========================================================= */


CREATE TABLE village_locations (
    village_id INTEGER PRIMARY KEY,
    village VARCHAR(30) NOT NULL UNIQUE,
    latitude VARCHAR(30),
    longitude VARCHAR(30),
    total_population INTEGER NOT NULL
);

CREATE TABLE jurisdiction_hierarchy (
    id INTEGER PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    type VARCHAR(20) NOT NULL,
    parent_id INTEGER,
    CONSTRAINT fk_jurisdiction_parent
        FOREIGN KEY (parent_id)
        REFERENCES jurisdiction_hierarchy(id)
);

CREATE TABLE beneficiary_partner_data (
    partner_id INTEGER PRIMARY KEY,
    partner VARCHAR(30) NOT NULL,
    village VARCHAR(30) NOT NULL,
    beneficiaries INTEGER NOT NULL,
    beneficiary_type VARCHAR(30) NOT NULL,
    CONSTRAINT fk_beneficiary_village
        FOREIGN KEY (village)
        REFERENCES village_locations(village)
);
INSERT INTO village_locations
    (village_id, village, latitude, longitude, total_population)
VALUES
    (1, 'Dharkenley', '2.0469', '45.3182', 5000),
    (2, 'Bulo-Kahin', '2.0560', '45.3250', 4200);
   /* =========================================================
   TASK 1: EXPLORE THE DATA
   ========================================================= */

-- 1a. Display all records from each table. 
    SELECT * FROM beneficiary_partner_data;
SELECT * FROM village_locations;
SELECT * FROM jurisdiction_hierarchy;
-- 1b. Display only partner, village, and beneficiaries.
SELECT partner, village, beneficiaries
FROM beneficiary_partner_data;
-- 1c. Find villages with a population greater than 4,500.
SELECT *
FROM village_locations
WHERE total_population > 4500;
-- 1d. Find records where the beneficiary type is Households.
SELECT *
FROM beneficiary_partner_data
WHERE beneficiary_type = 'Households';

/* =========================================================
   TASK 2: CONVERT BENEFICIARY COUNTS
   ========================================================= */
   -- Convert each household to an estimated six individuals.
SELECT
    partner_id,
    partner,
    village,
    beneficiaries,
    beneficiary_type,
    CASE
        WHEN beneficiary_type = 'Individuals' THEN beneficiaries
        WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
    END AS individual_beneficiaries
FROM beneficiary_partner_data;

/* =========================================================
   TASK 3: PARTNER ANALYSIS
   ========================================================= */

SELECT
    partner,
    SUM(
        CASE
            WHEN beneficiary_type = 'Individuals' THEN beneficiaries
            WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
        END
    ) AS total_individual_beneficiaries,
    COUNT(DISTINCT village) AS villages_served,
    ROUND(
        AVG(
            CASE
                WHEN beneficiary_type = 'Individuals' THEN beneficiaries
                WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
            END
        ),
        2
    ) AS average_individual_beneficiaries_per_record
FROM beneficiary_partner_data
GROUP BY partner
ORDER BY total_individual_beneficiaries DESC;

/* =========================================================
   TASK 4: VILLAGE COVERAGE
   ========================================================= */

-- Each row shows one partner's reach in one village.
-- Multiplying by 100.0 ensures a decimal percentage.
SELECT
    b.partner,
    b.village,
    CASE
        WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
        WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
    END AS individual_beneficiaries,
    v.total_population AS village_population,
    ROUND(
        (
            CASE
                WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
                WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
            END * 100.0 / v.total_population
        ),
        2
    ) AS coverage_percentage
FROM beneficiary_partner_data AS b
INNER JOIN village_locations AS v
    ON b.village = v.village;
    
/* =========================================================
   TASK 5: ADD DISTRICT INFORMATION
   ========================================================= */

-- Join the village hierarchy row to its parent district row.
SELECT
    b.partner,
    b.village,
    d.name AS district,
    CASE
        WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
        WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
    END AS individual_beneficiaries
FROM beneficiary_partner_data AS b
INNER JOIN jurisdiction_hierarchy AS village_h
    ON b.village = village_h.name
    AND village_h.type = 'Village'
INNER JOIN jurisdiction_hierarchy AS d
    ON village_h.parent_id = d.id
    AND d.type = 'District';
    
   /* =========================================================
   TASK 6: MULTIPLE-PARTNER VILLAGES
   ========================================================= */
SELECT
    village,
    COUNT(DISTINCT partner
) AS number_of_distinct_partners
FROM beneficiary_partner_data
GROUP BY village
HAVING COUNT(DISTINCT partner) > 1;
/* =========================================================
   TASK 7: CREATE SUMMARY TABLES
   ========================================================= */

-- Remove existing summary tables so this section can be rerun safely.
DROP TABLE IF EXISTS Partner_summary;
DROP TABLE IF EXISTS District_summary;

-- Partner-level summary.
CREATE TABLE Partner_summary AS
SELECT
    partner,
    SUM(
        CASE
            WHEN beneficiary_type = 'Individuals' THEN beneficiaries
            WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
        END
    ) AS total_beneficiaries,
    COUNT(DISTINCT village) AS villages_served,
    ROUND(
        AVG(
            CASE
                WHEN beneficiary_type = 'Individuals' THEN beneficiaries
                WHEN beneficiary_type = 'Households' THEN beneficiaries * 6
            END
        ),
        2
    ) AS average_beneficiaries
FROM beneficiary_partner_data
GROUP BY partner;
-- District-level summary. The join through the village hierarchy
-- assigns every beneficiary record to the correct district.
CREATE TABLE District_summary AS
SELECT
    d.name AS district,
    SUM(
        CASE
            WHEN b.beneficiary_type = 'Individuals' THEN b.beneficiaries
            WHEN b.beneficiary_type = 'Households' THEN b.beneficiaries * 6
        END
    ) AS total_individual_beneficiaries,
    COUNT(DISTINCT b.village) AS number_of_villages_served
FROM beneficiary_partner_data AS b
INNER JOIN jurisdiction_hierarchy AS village_h
    ON b.village = village_h.name
    AND village_h.type = 'Village'
INNER JOIN jurisdiction_hierarchy AS d
    ON village_h.parent_id = d.id
    AND d.type = 'District'
GROUP BY d.name;

   -- Display the completed summary tables.
SELECT *
FROM Partner_summary
ORDER BY total_beneficiaries DESC;

SELECT *
FROM District_summary
ORDER BY total_individual_beneficiaries DESC;

    


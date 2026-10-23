/* =====================================================================
   Lead-to-Deal: Olist Funnel Performance Dashboard
   SQL Server script: rebuild, clean view, checks, profiling, analysis
   Data: Olist Marketing Funnel (leads + closed deals)
   Note: SR / SDR names are fictional placeholders (dataset is anonymized)
   ===================================================================== */

/* ---------- PART 1: CREATE DATABASE ---------- */
USE master;
GO
IF DB_ID('Olist_Funnel') IS NOT NULL
BEGIN
    ALTER DATABASE Olist_Funnel SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE Olist_Funnel;
END
GO
CREATE DATABASE Olist_Funnel;
GO

/* ---------- MANUAL STEP: Import Flat File (right-click DB > Tasks) ----------
   olist_marketing_qualified_leads_dataset.csv -> stg_leads  (8000 rows)
   olist_closed_deals_dataset.csv              -> stg_deals  (842 rows)
   sr_lookup.csv                               -> sr         (22 rows)
   sdr_lookup.csv                              -> sdr        (32 rows)
   For sr / sdr: ID column is the primary key, Allow Nulls off.
------------------------------------------------------------------------- */

/* ---------- PART 2: TABLES, CLEANING, LOAD ---------- */
USE Olist_Funnel;
GO

CREATE TABLE dbo.leads (
    mql_id             nvarchar(32) NOT NULL PRIMARY KEY,
    first_contact_date date,
    landing_page_id    nvarchar(32),
    origin             nvarchar(30)
);

CREATE TABLE dbo.deals (
    mql_id                   nvarchar(32) NOT NULL PRIMARY KEY,
    seller_id                nvarchar(32),
    sdr_id                   nvarchar(50),   -- must match dbo.sdr.sdr_id
    sr_id                    nvarchar(50),   -- must match dbo.sr.sr_id
    won_date                 datetime,
    business_segment         nvarchar(50),
    lead_type                nvarchar(30),
    lead_behaviour_profile   nvarchar(32),
    business_type            nvarchar(20),
    declared_monthly_revenue decimal(18,2),
    revenue_outlier_flag     bit NOT NULL DEFAULT 0,
    FOREIGN KEY (mql_id) REFERENCES dbo.leads(mql_id),
    FOREIGN KEY (sr_id)  REFERENCES dbo.sr(sr_id),
    FOREIGN KEY (sdr_id) REFERENCES dbo.sdr(sdr_id)
);
GO

-- Cleaning rules applied during load:
--  * origin NULL (60)               -> 'unknown'
--  * business_segment/lead_type/business_type NULL (1/6/10) -> mode
--  * lead_behaviour_profile NULL (177, 21%) -> 'Unknown' (too large for mode)
--  * declared_monthly_revenue 0 (797 = "not declared") -> NULL
--  * has_company, has_gtin, average_stock, declared_product_catalog_size
--    (about 92% empty) are not loaded
INSERT INTO dbo.leads (mql_id, first_contact_date, landing_page_id, origin)
SELECT mql_id, first_contact_date, landing_page_id, COALESCE(origin, 'unknown')
FROM dbo.stg_leads;

INSERT INTO dbo.deals (mql_id, seller_id, sdr_id, sr_id, won_date, business_segment,
                       lead_type, lead_behaviour_profile, business_type, declared_monthly_revenue)
SELECT mql_id, seller_id, sdr_id, sr_id, won_date,
       COALESCE(business_segment, 'home_decor'),
       COALESCE(lead_type, 'online_medium'),
       COALESCE(lead_behaviour_profile, 'Unknown'),
       COALESCE(business_type, 'reseller'),
       NULLIF(CAST(declared_monthly_revenue AS decimal(18,2)), 0)
FROM dbo.stg_deals;

-- Revenue outlier flag: IQR upper fence 302,500 (Q1 15,000, Q3 130,000)
-- plus a business-sense floor of 1,000 (catches the 6.00 entry)
UPDATE dbo.deals
SET revenue_outlier_flag = 1
WHERE declared_monthly_revenue > 302500 OR declared_monthly_revenue < 1000;
GO

/* ---------- PART 3: CLEAN VIEW FOR EXCEL (one row per lead) ---------- */
-- Deal columns are 'No deal' for leads that never converted.
-- days_to_win, won_date and revenue stay NULL on purpose: 0 would distort averages.
CREATE VIEW dbo.vw_funnel_clean AS
SELECT
    l.mql_id,
    l.first_contact_date,
    l.landing_page_id,
    l.origin,
    CASE WHEN d.mql_id IS NOT NULL THEN 1 ELSE 0 END AS is_won,
    CASE WHEN d.mql_id IS NULL THEN 1 ELSE 0 END AS Missed_Opportunity,
    d.won_date,
    CASE WHEN d.mql_id IS NOT NULL
          AND DATEDIFF(day, l.first_contact_date, d.won_date) >= 0
         THEN DATEDIFF(day, l.first_contact_date, d.won_date)
    END AS days_to_win,
    COALESCE(d.business_segment, 'No deal')        AS business_segment,
    COALESCE(d.lead_type, 'No deal')               AS lead_type,
    COALESCE(d.lead_behaviour_profile, 'No deal')  AS lead_behaviour_profile,
    COALESCE(d.business_type, 'No deal')           AS business_type,
    COALESCE(sr.sr_name, 'No deal')                AS sales_rep,
    COALESCE(sdr.sdr_name, 'No deal')              AS sdr_name,
    d.declared_monthly_revenue,
    COALESCE(d.revenue_outlier_flag, 0)            AS revenue_outlier_flag
FROM dbo.leads AS l
LEFT JOIN dbo.deals AS d   ON l.mql_id = d.mql_id
LEFT JOIN dbo.sr    AS sr  ON d.sr_id  = sr.sr_id
LEFT JOIN dbo.sdr   AS sdr ON d.sdr_id = sdr.sdr_id;
GO

/* ---------- PART 4: CHECKS ---------- */
SELECT
  (SELECT COUNT(*) FROM dbo.leads) AS leads,                                           -- 8000
  (SELECT COUNT(*) FROM dbo.deals) AS deals,                                           -- 842
  (SELECT COUNT(*) FROM dbo.sr)    AS sr,                                              -- 22
  (SELECT COUNT(*) FROM dbo.sdr)   AS sdr,                                             -- 32
  (SELECT COUNT(*) FROM dbo.leads WHERE origin IS NULL) AS null_origin,                -- 0
  (SELECT COUNT(*) FROM dbo.deals WHERE declared_monthly_revenue IS NULL) AS null_rev, -- 797
  (SELECT SUM(CAST(revenue_outlier_flag AS int)) FROM dbo.deals) AS outliers;          -- 4

SELECT COUNT(*) AS total_rows, SUM(is_won) AS deals, COUNT(days_to_win) AS cycle_rows
FROM dbo.vw_funnel_clean;                                                              -- 8000, 842, 841

SELECT COUNT(*) AS no_deal_rows
FROM dbo.vw_funnel_clean WHERE sales_rep = 'No deal';                                   -- 7158

/* ---------- PART 5: PROFILING NOTES ---------- */
-- Outlier limits for declared_monthly_revenue (IQR rule)
WITH q AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY declared_monthly_revenue) OVER () AS Q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY declared_monthly_revenue) OVER () AS Q3
    FROM dbo.deals
    WHERE declared_monthly_revenue IS NOT NULL
)
SELECT Q1, Q3, Q3 - Q1 AS IQR,
       Q1 - 1.5 * (Q3 - Q1) AS lower_limit,       -- -157,500
       Q3 + 1.5 * (Q3 - Q1) AS upper_limit        -- 302,500
FROM q;

-- Data-quality issue: deals won BEFORE the first contact date (expected 1 row, -2 days)
SELECT d.mql_id, l.first_contact_date, d.won_date,
       DATEDIFF(day, l.first_contact_date, d.won_date) AS days_diff
FROM dbo.deals AS d
INNER JOIN dbo.leads AS l ON d.mql_id = l.mql_id
WHERE d.won_date < l.first_contact_date;

/* ---------- PART 6: ANALYSIS QUERIES ----------
   Each query: the business question, what the result showed, and where it is used. */

/* Q1. OVERALL CONVERSION RATE
   Question : What share of all leads became a closed deal?
   Result   : 8,000 leads, 842 deals, 10.52%
   Use      : Headline KPI tile; also the baseline to compare every channel against */
SELECT COUNT(*) AS leads,
       COUNT(d.mql_id) AS deals_won,
       CAST(COUNT(d.mql_id) * 100.0 / COUNT(*) AS decimal(5,2)) AS conversion_rate
FROM dbo.leads AS l
LEFT JOIN dbo.deals AS d ON l.mql_id = d.mql_id;

/* Q2. CONVERSION BY LEAD ORIGIN (channel)
   Question : Which channels bring leads that actually close?
   Result   : unknown 16.65% (includes the 60 NULLs we filled), paid_search 12.30%,
              organic_search 11.80%, direct_traffic 11.22%, referral 8.45%, social 5.56%,
              display 5.08%, other_publicities 4.62%, email 3.04%, other 2.67%
   Use      : Bar chart "Conversion by origin"; email and other convert worst */
SELECT l.origin,
       COUNT(*) AS leads,
       COUNT(d.mql_id) AS deals_won,
       CAST(COUNT(d.mql_id) * 100.0 / COUNT(*) AS decimal(5,2)) AS conversion_rate
FROM dbo.leads AS l
LEFT JOIN dbo.deals AS d ON l.mql_id = d.mql_id
GROUP BY l.origin
ORDER BY conversion_rate DESC;

/* Q3. LEADS AND DEALS PER MONTH
   Question : How do lead volume and closed deals move over time?
   Result   : Leads peak in Apr 2018 (1,352) and stop after May 2018. Deals peak in
              Apr 2018 (207) and tail off until Nov 2018. The first deals appear in Dec 2017,
              about 6 months after the first leads.
   Note     : Months after May 2018 have 0 leads because the data ends, not because
              lead generation fell.
   Use      : Line / clustered column chart "Leads vs deals by month"
   Technique: date spine (GENERATE_SERIES) so months with no data still appear */
WITH lead_month AS (
    SELECT CAST(DATETRUNC(month, first_contact_date) AS date) AS lead_month, COUNT(*) AS leads
    FROM dbo.leads
    GROUP BY DATETRUNC(month, first_contact_date)
),
deal_month AS (
    SELECT CAST(DATETRUNC(month, won_date) AS date) AS deal_month, COUNT(*) AS deals
    FROM dbo.deals
    GROUP BY DATETRUNC(month, won_date)
),
date_sequence AS (
    SELECT DATEADD(month, value, '2017-06-01') AS sequence_date
    FROM GENERATE_SERIES(0, 17)
)
SELECT CAST(sequence_date AS date) AS month,
       COALESCE(leads, 0) AS leads,
       COALESCE(deals, 0) AS deals
FROM date_sequence
LEFT JOIN lead_month ON sequence_date = lead_month
LEFT JOIN deal_month ON sequence_date = deal_month
ORDER BY sequence_date;

/* Q4. SALES CYCLE LENGTH (days from first contact to won)
   Question : How long does it take to close a deal?
   Result   : 841 deals, average 48.5 days, MEDIAN 14 days, min 0, max 427
   Note     : The average is pulled up by a few very long cycles, so the median is the
              headline number. The one deal won 2 days BEFORE first contact (data error)
              is excluded by the >= 0 filter.
   Use      : KPI tile "Median days to win" */
WITH cycle AS (
    SELECT DATEDIFF(day, l.first_contact_date, d.won_date) AS days_to_win
    FROM dbo.leads AS l
    INNER JOIN dbo.deals AS d ON l.mql_id = d.mql_id
    WHERE DATEDIFF(day, l.first_contact_date, d.won_date) >= 0
)
SELECT DISTINCT
    COUNT(*) OVER () AS deals,
    ROUND(AVG(CAST(days_to_win AS decimal(10,2))) OVER (), 1) AS avg_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_win) OVER () AS median_days,
    MIN(days_to_win) OVER () AS min_days,
    MAX(days_to_win) OVER () AS max_days
FROM cycle;

/* Q5. DEALS BY BUSINESS SEGMENT
   Question : Which seller segments close the most deals?
   Result   : home_decor 106 (12.59%, includes 1 NULL filled with the mode),
              health_beauty 93 (11.05%), car_accessories 77 (9.14%). 33 segments in total.
   Note     : Segment exists only for won deals, so this is a deal count, not a conversion rate.
   Use      : Bar chart of the top 8-10 segments; group the rest as "Other" */
SELECT business_segment,
       COUNT(*) AS deal_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS deal_share
FROM dbo.deals
GROUP BY business_segment
ORDER BY deal_count DESC;

/* Q6a. DEALS PER SALES REP (SR)
   Question : How are closed deals spread across the sales reps?
   Result   : 22 reps. Top rep closes 15.80%. The TOP 5 REPS CLOSE ABOUT 49.4% of deals,
              so closing is concentrated in a few people.
   Caveat   : We do not know how many leads each rep handled, so this shows concentration,
              not who is "better". Rep names are fictional placeholders.
   Use      : Bar chart "Deals by sales rep" */
SELECT s.sr_name AS sales_rep,
       COUNT(*) AS deal_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS deal_share
FROM dbo.deals AS d
INNER JOIN dbo.sr AS s ON d.sr_id = s.sr_id
GROUP BY s.sr_name
ORDER BY deal_count DESC;

/* Q6b. DEALS PER SDR (sales development rep, the first contact)
   Result   : 32 SDRs. Top SDR closes 16.63%. The top 5 SDRs account for about 49.9%.
   Use      : Bar chart "Deals by SDR" */
SELECT s.sdr_name AS sdr,
       COUNT(*) AS deal_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS deal_share
FROM dbo.deals AS d
INNER JOIN dbo.sdr AS s ON d.sdr_id = s.sdr_id
GROUP BY s.sdr_name
ORDER BY deal_count DESC;

/* Q7a. DEALS BY LEAD TYPE
   Question : What kind of seller closes?
   Result   : online_medium 338 (40.14%, includes 6 NULLs filled with the mode),
              online_big 126 (14.96%), industry 123 (14.61%), offline 104 (12.35%)
   Use      : Bar chart or slicer */
SELECT lead_type,
       COUNT(*) AS deal_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS deal_share
FROM dbo.deals
GROUP BY lead_type
ORDER BY deal_count DESC;

/* Q7b. DEALS BY LEAD BEHAVIOUR PROFILE
   Result   : cat 407 (48.34%), Unknown 177 (21.02%, these are the filled NULLs),
              eagle 123 (14.61%), wolf 95 (11.28%), shark 24 (2.85%).
              16 deals have two profiles in one cell (e.g. "cat, wolf").
   Use      : Donut or bar chart; consider grouping the two-profile rows as "Mixed" */
SELECT lead_behaviour_profile,
       COUNT(*) AS deal_count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS deal_share
FROM dbo.deals
GROUP BY lead_behaviour_profile
ORDER BY deal_count DESC;

/* Q8. MEDIAN REVENUE BY SEGMENT  -  SKIPPED ON PURPOSE
   Only 45 deals declared a monthly revenue, spread over 33 segments, so per-segment
   medians would mean nothing. The overall median of declared revenue is 50,000.
   Revenue outliers (6.00, 500,000, 8,000,000, 50,000,000) are flagged in revenue_outlier_flag. */

/* Q9. CONVERSION BY LANDING PAGE (pages with at least 20 leads)
   Question : Which landing pages turn leads into deals, and which waste traffic?
   Result   : 64 pages qualify. Best: 25.00% (20 leads, 5 deals). Strong high-volume pages:
              883 leads at 19.71%, 912 leads at 18.75%. WEAK high-volume pages worth fixing:
              495 leads at 5.45%, 445 at 6.97%, 310 at 6.77%.
   Why >= 20 : with only a few leads a page can show 50% by luck, so we set a minimum.
   Use      : Table or bar chart of top and bottom pages; main recommendation of the project
   Note     : HAVING filters the group size, so it counts LEADS (l.mql_id), not deals. */
SELECT l.landing_page_id,
       COUNT(l.mql_id) AS leads,
       COUNT(d.mql_id) AS deals,
       CAST(COUNT(d.mql_id) * 100.0 / COUNT(l.mql_id) AS decimal(5,2)) AS conversion
FROM dbo.leads AS l
LEFT JOIN dbo.deals AS d ON l.mql_id = d.mql_id
GROUP BY l.landing_page_id
HAVING COUNT(l.mql_id) >= 20
ORDER BY conversion DESC;

/* Q10 (bonus). LEADS THAT NEVER BECAME A DEAL
   Result   : 7,158 leads (89.48%), the "Missed_Opportunity" rows in the view
   Check    : 8,000 - 842 = 7,158 */
SELECT COUNT(*) AS leads_without_deals
FROM dbo.leads
WHERE mql_id NOT IN (SELECT mql_id FROM dbo.deals);

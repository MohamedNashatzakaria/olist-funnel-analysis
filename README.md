# Lead-to-Deal: Olist Funnel Performance Dashboard

An end-to-end funnel analysis built with **SQL Server** and **Excel**: raw CSVs, profiling and cleaning in SQL, a clean view, analysis queries, an interactive dashboard and a written report.

![Dashboard overview](images/overview.png)

## Business question
Where do leads convert into closed deals, where do they not, and what can the data not tell us?

## Key findings
- **10.53%** of leads become deals (842 of 8,000). The median deal closes in **14 days** (average 48.5, longest 427).
- **Channels differ about 4x:** paid_search converts at 12.30%, organic_search at 11.80%, email at 3.04%.
- **Landing pages matter:** three high-traffic pages convert at 5.45% to 6.97%, while pages with similar traffic reach 18.75% to 20.30%.
- **Closing is concentrated:** the top 5 of 22 sales reps closed 49.4% of deals.
- **Not measurable with this data:** SDR qualification performance (see Limitations).

## Tools
SQL Server (T-SQL: CTEs, window functions, `PERCENTILE_CONT`, date spine with `GENERATE_SERIES`), Excel (pivot tables, slicers, pivot charts), Python/reportlab for the PDF layout.

## Repository structure
| Folder | Contents |
|---|---|
| `sql/` | `olist_funnel_project.sql`: database rebuild, cleaning, the view, checks and all analysis queries, each with a comment on the question and result |
| `dashboard/` | The Excel dashboard (3 tabs: Overview, Origin Analysis, Rep Performance) |
| `report/` | `Olist_Funnel_Report.pdf`: 5-page report with findings, data quality notes and recommendations |
| `images/` | Dashboard screenshots |
| `data/` | Lookup tables for sales rep and SDR names (fictional, see below) |

## Data
Public **Olist Marketing Funnel** dataset on Kaggle (8,000 marketing qualified leads and 842 closed deals). The raw CSVs are not included here; download them from Kaggle and check the dataset page for its license terms: https://www.kaggle.com/olistbr/marketing-funnel-olist

The dataset is anonymized. **Sales rep and SDR names are fictional placeholders** I assigned to the IDs for readability.

## How to reproduce
1. Download the two CSVs from Kaggle.
2. In SQL Server, create the database and import the CSVs as `stg_leads` and `stg_deals`, and `data/sr_lookup.csv` and `data/sdr_lookup.csv` as `sr` and `sdr` (SSMS: Tasks, Import Flat File).
3. Run `sql/olist_funnel_project.sql` from Part 2 onward.
4. Connect Excel to the `vw_funnel_clean` view (Data, Get Data, From SQL Server).

## Cleaning decisions
| Issue | Action |
|---|---|
| 60 leads with no origin | Set to `unknown` |
| 1, 6 and 10 empty values in segment, lead type, business type | Filled with the most common value (under 2% each) |
| 177 empty behaviour profiles (21%) | Set to `Unknown` (a most-common fill would inflate one group) |
| 4 columns about 92% empty | Not loaded, not imputed |
| 797 revenue zeros meaning "not declared" | Set to NULL |
| 4 revenue outliers | Kept and flagged (`revenue_outlier_flag`) |
| 1 deal won 2 days before first contact | Kept, excluded from sales-cycle statistics |

## Limitations
- Only won deals carry attributes, and there is no lost or open status, so 10.53% is the share of leads won, not a win rate.
- The SDR and sales rep are recorded only for closed deals, so SDR qualification cannot be measured. The report lists the fields I would request: lead owner on every lead, lead status and loss reason, and a qualification date.
- Revenue is declared for only 45 of 842 deals, so revenue figures are indicative only.

## Author
Mohamed Nashat. Built as a capstone for a data analytics diploma.

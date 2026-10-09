# Predictors of Zero-Dose Status Among Children in Northwest Nigeria

Analysis of individual- and household-level predictors of zero-dose
immunization status (children who have received no dose of a DTP-containing
vaccine) among children aged 12–23 months in Northwest Nigeria, using the
2023 - 2024 Nigeria Demographic and Health Survey (NDHS).

## Data Source

This analysis uses the Children's Recode file from the **2023-2024 Nigeria DHS**
(`NGKR8BFL.dta`), obtained through [The DHS Program](https://dhsprogram.com/data/dataset_admin/login_main.cfm).

**The raw and processed data files are not included in this repository.**
DHS microdata is subject to its own Data Use Agreement, which prohibits
redistribution — even in recoded/derived form. Researchers who want to
reproduce this analysis must request access to the Nigeria 2023-2024 DHS dataset
directly from The DHS Program and place the children's recode file at
`data/raw/dhs/NGKR8BFL.dta` before running the pipeline below.

## Repository Structure
```
├── dashboard/
│   └── zero_dose_nw_dashboard.pbix   # Interactive Power BI dashboard
├── data/
│   ├── raw/
│   │   ├── boundaries/      # Nigeria admin-1 shapefile (public, included)
│   │   └── dhs/             # DHS microdata (not included — see above)
│   └── processed/           # Cleaned analytic file (not included — derived from DHS data)
├── scripts/
│   ├── python/
│   │   └── zero_dose_nw_data_ETL_script.py   # Cleans and transforms raw DHS data into the analytic dataset
│   └── R/
│       └── zero_dose_nw_analysis_script.R    # Survey-weighted regression, tables, figures
├── outputs/
│   ├── tables/     # Table 1 (weighted characteristics), Table 2 (regression results)
│   ├── figures/    # Forest plot, persona predictions, state-level prevalence map
│   ├── gis/        # State-level zero-dose prevalence data
│   └── powerbi/    # Exported data feeding the Power BI dashboard
├── .gitignore
├── LICENSE
└── README.md
```

## Reproducing the Analysis

1. Place `NGKR8BFL.dta` at `data/raw/dhs/NGKR8BFL.dta`.
2. Run the Python ETL script to build the cleaned analytic dataset: scripts/python/zero_dose_nw_data_ETL_script.py
3. Run the R script to generate the regression tables, forest plot, and
   state-level prevalence map: scripts/R/zero_dose_nw_analysis_script.R
4. Open `dashboard/zero_dose_nw_dashboard.pbix` in Power BI Desktop to
   explore the interactive dashboard, which reads from the exported data
   in `outputs`.

## Methods Summary

- **Outcome:** Zero-dose status, defined as no receipt of the first dose of
  a DTP-containing vaccine (captured via the legacy DPT1 variable `h3` and
  the current Pentavalent1 variable `h51`, combined — a sensitivity check
  confirmed these fully agree in this cohort, with zero discordant cases).
- **Sample:** Children aged 12–23 months in Northwest Nigeria (Sokoto,
  Zamfara, Katsina, Jigawa, Kano, Kaduna, Kebbi).
- **Design:** Survey-weighted multivariate logistic regression accounting
  for the DHS complex sample design (strata, clusters, weights).
- **Predictors:** Maternal education, household wealth index, locality
  type, physical distance to a health facility, place of delivery,
  antenatal care receipt, and child's sex.

## License

Code in this repository is released under the [MIT License](LICENSE).
This license applies to the analysis code only — it does not extend to
any DHS data, which remains governed by The DHS Program's own Data Use
Agreement.

## Author

Jibrin Gowin
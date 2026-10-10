# Methodology

This document describes, in full, how raw NDHS 2023–2024 microdata becomes
the final analytic outputs in this repository: every variable used, every
recoding decision, every missing-data rule, and every modeling choice. It is
written so another analyst can audit or reproduce the pipeline without
reading the source code line by line — though the code remains the final
authority, and this document is kept in sync with it.

## 1. Data Source and Sample Definition

- **Source:** Nigeria DHS 2023–2024, Children's Recode file (`NGKR8BFL.dta`).
- **Geographic restriction:** Northwest Nigeria only — children in households
  where `v024` (geopolitical zone) equals `1`. The Northwest comprises seven
  states: Sokoto, Zamfara, Katsina, Jigawa, Kano, Kaduna, Kebbi.
- **Age restriction:** children aged 12–23 months at the time of interview
  (`b8 == 1`, the DHS age-in-years code reserved for this band). Codes
  outside `{0, 1, 2, 3, 4}` are treated as irregular, set to missing, and
  excluded before any other filtering — so a corrupted age code cannot be
  silently counted into any age band.
- This age band is the WHO/Gavi standard reference population for the
  zero-dose indicator: a child is old enough to have completed dose 1 of a
  DTP-containing vaccine regardless of when in their first year they
  received it.

## 2. Variable Codebook

| DHS Variable | Meaning | Role in Analysis |
|---|---|---|
| `caseid` | Unique case identifier | ID — carried through, never analyzed |
| `v001` | Cluster number | Survey design: PSU/cluster for `svydesign(ids = ~v001)` |
| `v002` | Household number | ID — carried through, never analyzed |
| `v023` | Sample design stratification | Survey design: `svydesign(strata = ~v023)` |
| `v024` | Geopolitical zone | Cohort filter (Northwest = code 1) |
| `sstate` | State | Recoded to `state_code` (named states), used for sub-national breakdowns and the spatial map |
| `v005` | Individual sample weight (6 implied decimals) | Divided by 1,000,000 → `sample_weight`, used in `svydesign(weights = ~sample_weight)` |
| `h3` | DPT1 vaccination status (legacy label) | Combined with `h51` into the outcome — see §3 |
| `h51` | Pentavalent dose 1 vaccination status (current label) | Combined with `h3` into the outcome — see §3 |
| `v025` | Type of place of residence | Recoded to `is_rural` (1 = Rural, 0 = Urban) |
| `v467d` | Distance to health facility is a problem | Recoded to `distance_barrier` (1 = Barrier, 0 = No Barrier) |
| `m14` | Number of antenatal care visits | Recoded to `received_anc` (1 if `m14 > 0`, i.e. at least one ANC visit) |
| `m15` | Place of delivery | Recoded to `facility_delivery` via the clinical-facility code list — see §6 |
| `b4` | Biological sex of child | Recoded to `is_female` (1 = Female, 0 = Male) |
| `v106` | Highest maternal education level | Recoded to `maternal_education` (No Education / Primary / Secondary / Higher) |
| `v190` | Wealth index quintile | Recoded to `wealth_index` (Poorest / Poorer / Middle / Richer / Richest) |
| `b8` | Child's current age in years | Used only to apply the 12–23 month filter; dropped from final predictors |

## 3. Outcome Variable: Zero-Dose Status

### 3.1 Why two source variables are combined

NDHS 2023–2024 is a transition-era survey for this antigen: it carries both
the legacy DPT1 variable (`h3`) and the current Pentavalent-1 variable
(`h51`) as parallel fields, reflecting that some children's immunization
cards record the vaccine under one label and some under the other.
Operationalizing "received dose 1 of a DTP-containing vaccine" using `h3`
alone risks misclassifying a child as zero-dose when they actually have a
valid Pentavalent1 record under `h51`, and vice versa.

### 3.2 Combination rule

A child is coded as **having received dose 1** if *either* `h3` or `h51`
shows a valid receipt code:
- `1` = vaccination date recorded on card
- `2` = reported by mother (no card seen)
- `3` = card seen, vaccination marked, no date recorded

A child is coded as **zero-dose** only if neither variable shows a valid
receipt code. The combined outcome is treated as missing only if *both*
`h3` and `h51` are unknown (DHS "don't know" code `8` or missing code `9`,
both mapped to `NaN` before this step) — one source being known is
sufficient to classify the child, even if the other field is blank because
that vaccine name never applied to their card.

```
dose1_combined =
    NaN  if h3 is NaN AND h51 is NaN
    1    if h3 in {1,2,3} OR h51 in {1,2,3}
    0    otherwise

is_zero_dose = 1 - dose1_combined
```

### 3.3 Empirical verification

Before trusting this combination rule, the two source variables were
cross-tabulated directly against the raw `.dta` file for this cohort:

| | `h51` not received | `h51` received |
|---|---|---|
| `h3` ≠ 0 (received, or don't know) | 52 | 8,864 |
| `h3` == 0 (not received) | 6,000 | **0** |
| `h3` is NA (not applicable) | 12,867 | 0 |

The critical cell — children with `h3 == 0` **and** a valid `h51` receipt —
is **zero**. No child in this cohort was misclassified by using `h3` alone;
the two variables are fully concordant in this sample. The combined-outcome
logic is retained regardless, both because it is the methodologically
correct construction (concordance is a property of this dataset, not a
guarantee for every re-run of this pipeline on other zones or survey
years) and because it documents that the check was performed rather than
assumed.

## 4. Missing Data Handling

### 4.1 Survey-specific missing codes

Raw DHS placeholder codes for "don't know" / "missing" are mapped to
standard `NaN` before any other processing:

| Variable | Codes mapped to NaN |
|---|---|
| `h3`, `h51` | 8 (don't know), 9 (missing) |
| `v467d` | 9 (missing) |
| `m15` | 99 (missing) |
| `v106` | 9 (missing) |
| `m14` | 98 (don't know), 99 (missing) |

### 4.2 The outcome-driven drop rule

Cases with a missing **combined outcome** (`dose1_combined`, not raw `h3`
or `h51` individually — see §3) are dropped unconditionally; the primary
outcome is never imputed. Raw `h3` and `h51` are excluded from all
downstream predictor-level missingness handling once consumed into the
combined outcome, so neither is separately dropped-for or imputed as if it
were an independent predictor.

### 4.3 The 5% predictor rule

For every remaining predictor, a missingness rate is computed once, on the
cohort as it stands immediately after the outcome-driven drop (not
recomputed column-by-column as rows are removed — this keeps the result
independent of the order predictors happen to be processed in):

- **Missingness < 5%:** cases with a missing value on that predictor are
  dropped (complete-case approach — justified by the low rate).
- **Missingness ≥ 5%:** the predictor is imputed instead of dropped, using
  the mode (if the predictor has fewer than 10 distinct values — i.e. a
  categorical/discrete field) or the median (otherwise).
- **Design and identifier columns are never dropped-for or imputed under
  any circumstance**: `caseid`, `v001` (cluster), `v002` (household),
  `v023` (stratum), `v024` (zone), `sstate` (state). A missing design field
  means the record's sampling information is broken, not something to
  estimate.

### 4.4 Data-integrity audits (run before missingness resolution)

- **Sex ratio check:** the proportion female (`b4 == 2`) is expected to
  fall between 0.45 and 0.55; a value outside that range triggers a
  warning (not a halt) to prompt manual review of the zone filter.
- **Wealth index bounds check:** all non-missing `v190` values are
  confirmed to fall within the expected `{1,2,3,4,5}` range.
- **Age irregularity audit:** the proportion of `b8` values outside
  `{0,1,2,3,4}` is reported before those values are nulled out.
- **Missingness-by-state audit:** the combined outcome's missingness rate
  is computed per state and written to
  `outputs/tables/zero_dose_missingness_by_state.csv`; a state exceeding 5%
  missingness triggers a warning, flagging where non-response may be
  geographically concentrated rather than random.

## 5. Facility Delivery Classification

`facility_delivery` is a binary recode of `m15` (place of delivery) using
an explicit clinical-facility code list, verified against the 2023–2024
NDHS recode manual:

- **Public sector:** codes 21–27
- **Private sector:** codes 31, 32, 35–38
- **NGO / Faith-Based facilities:** codes 41, 42, 46

All three groups are coded `facility_delivery = 1` ("Clinical Facility").
**Faith-based facilities are deliberately grouped with clinical delivery,
not with the reference category** — this was a specific point checked
during table labeling, since "Home/Other" (the reference label) could be
misread as including faith-based settings. It does not; the reference
category (`facility_delivery = 0`) is home deliveries and any other code
not in the list above (e.g., "other," "in transit").

## 6. Survey Design Specification

The DHS sample is a stratified multi-stage cluster design, and all
estimates in this analysis — descriptive and regression — account for it
via the `survey` package rather than treating the data as a simple random
sample:

```r
svydesign(
  ids = ~v001,            # cluster (PSU)
  strata = ~v023,         # sampling stratum
  weights = ~sample_weight,  # v005 / 1,000,000
  nest = TRUE
)
options(survey.lonely.psu = "adjust")  # set before design object creation
```

`survey.lonely.psu = "adjust"` handles strata that, after the Northwest
zone filter, contain only a single PSU — without this, variance estimation
for such a stratum would fail outright rather than degrade gracefully.

Before any estimation, the design object is validated: construction
success, all weights strictly positive, and no missing stratum codes
(each triggers a warning or halt rather than silently proceeding).

## 7. Table 1 — Weighted Descriptive Characteristics

Produced with `gtsummary::tbl_svysummary()` on the survey design object,
stratified by zero-dose status, reporting **unweighted N with weighted
column percentages** (`"{n_unweighted} ({p}%)"`), with a design-based
chi-square-type test (`add_p()`) comparing characteristics across the two
outcome groups. Exported to both `.docx` (via `flextable`) and `.csv`.

## 8. Multivariate Logistic Regression (Table 2, aOR estimates)

```r
svyglm(
  is_zero_dose ~ maternal_education + wealth_index + is_rural +
                 distance_barrier + facility_delivery + received_anc + is_female,
  design = nw_survey_design,
  family = quasibinomial(link = "logit")
)
```

- **`quasibinomial`**, not `binomial`: required for survey-weighted
  logistic regression, since weighting inflates apparent precision that a
  standard binomial variance would understate.
- Coefficients are **exponentiated** to report adjusted odds ratios (aOR).
- **Reference categories:** No Education (maternal education), Poorest
  (wealth quintile), Urban (locality), No Barrier (distance), Home/Other
  (delivery place), No ANC (antenatal care), Male (child sex). Reference
  rows are reported as `1.00 (Ref.)` with CI/p-value cells marked
  "Reference," rather than left blank — ensuring no cell can be misread as
  missing data.
- **Significance threshold:** p-values below 0.05 are bolded in the
  rendered regression table (`bold_p(t = 0.05)`).

## 9. Figure 2 — Compounding Vulnerability Personas

Four hypothetical persona profiles are constructed to illustrate how risk
factors compound, and each profile's **predicted probability** of
zero-dose status is computed from the fitted model
(`predict(zero_dose_model, newdata = persona_profiles, type = "response")`)
— this is a model-based prediction for an illustrative covariate pattern,
not an observed subgroup in the data:

1. **Advantaged Baseline** — Urban, Richest, Higher Education, No Barrier,
   Received ANC, Facility Delivery
2. **Simple Rural Disadvantage** — Rural, Poorest, Higher Education, No
   Barrier, Received ANC, Facility Delivery
3. **Compounded Social Exclusion** — Rural, Poorest, No Education, No
   Barrier, Received ANC, Facility Delivery
4. **Triple Jeopardy** — Rural, Poorest, No Education, Barrier, No ANC,
   Home/Other delivery

All four personas hold child sex fixed at Female — the personas are
designed to isolate socioeconomic/access risk factors, not sex-based
variation.

## 10. Figure 1 — Forest Plot

Displays all 12 non-intercept model coefficients as points with 95% CI
error bars, on a log-scaled x-axis, ordered by a fixed logical sequence
(child sex → ANC → facility delivery → distance barrier → locality →
wealth quintile levels → maternal education levels) rather than by
coefficient magnitude, so related categories of the same predictor stay
visually grouped. A `coef_lookup` table is the single source of truth for
human-readable labels — it is also used to build the Power BI export
(`forest_plot_data.csv`), so the Word/PNG report and the Power BI dashboard
can never drift out of label-sync with each other.

## 11. Figure 3 — Spatial Prevalence Map

State-level weighted zero-dose prevalence (`survey_mean()`, accounting for
the complex design) is joined to the Nigeria admin-1 shapefile
(`data/raw/boundaries/nga_admin1.shp`) by **lowercased state name string
match** (`tolower(adm1_name)` against `tolower(state_name)`). This is a
name-matching join, not a code-based join — it is fragile to spelling
variants between the DHS state-name lookup and the shapefile's `adm1_name`
field, and was verified by confirming all 7 Northwest states matched
successfully before trusting the map output.

## 12. Known Limitations

- **Cross-sectional design:** this is a single survey wave; it describes
  association, not causal effect, between predictors and zero-dose status.
- **Recall bias:** where no vaccination card was available, vaccination
  status relies on maternal recall, which is known to be less reliable
  than card-based confirmation, particularly for older children in the
  12–23 month band.
- **Geographic scope:** estimates and model coefficients are specific to
  Northwest Nigeria and should not be generalized to other zones without
  re-running the analysis on that zone's subset.
- **Name-matching spatial join (§11):** a structural fragility — a future
  re-run against an updated or different-source shapefile should
  re-verify the join rather than assume it still matches cleanly.

## 13. Author

Jibrin Gowin — methodology documented alongside the analysis pipeline to
support independent reproduction and review.
import sys
from pathlib import Path
import numpy as np
import pandas as pd

# ==========================================
# PATHS: aligned to the project schema:
#   scripts/python/zero_dose_nw_data_ETL_script.py
#   data/raw/dhs/NGKR8BFL.dta
#   data/processed/zero-dose_nw_cleaned_data.csv
#   outputs/tables/zero_dose_missingness_by_state.csv
# ==========================================

BASE_DIR = Path(__file__).resolve().parents[2]  # project root, two levels up from scripts/python/

INPUT_DTA = BASE_DIR / "data" / "raw" / "dhs" / "NGKR8BFL.dta"
OUTPUT_CSV = BASE_DIR / "data" / "processed" / "zero-dose_nw_cleaned_data.csv"
AUDIT_CSV = BASE_DIR / "outputs" / "tables" / "zero_dose_missingness_by_state.csv"


# ==========================================
# CONFIGURATION & SCHEMA CONFIG
# ==========================================

ANALYTICAL_COLUMNS = [
    'caseid',    # Unique case identifier
    'v001',      # Cluster number
    'v002',      # Household number
    'v023',      # Stratification used in sample design
    'v024',      # Geopolitical zone 
    'sstate',    # State
    'v005',      # Individual sample weight
    'h3',        # DPT1 vaccination status
    'h51',       # Pentavalent 1 vaccination status
    'v025',      # Type of place of residence (urban/rural)
    'v467d',     # Distance to health facility or barrier
    'm14',       # Antenatal visits(ANC) during pregnancy 
    'm15',       # Facility of delivery 
    'b4',        # Biological sex of child
    'v106',      # Highest maternal education level
    'v190',      # Wealth index quintile
    'b8'         # Current age of child 
]

# Standardize expected types to check structure before operations
SCHEMA_EXPECTED_TYPES = {
    'caseid': 'object',
    'v001':   'numeric',
    'v002':   'numeric',
    'v024':   'numeric',
    'sstate': 'numeric',
    'v005':   'numeric',
    'h3':     'numeric',
    'h51':    'numeric',
    'v023':   'numeric',
    'v025':   'numeric',
    'v467d':  'numeric',
    'm14':    'numeric',
    'm15':    'numeric',
    'b4':     'numeric',
    'v106':   'numeric',
    'v190':   'numeric',
    'b8':     'numeric'
}

# Survey-specific missing values indicator code to map each to standard NaN
MISSINGNESS_MAP = {
    'h3': [8, 9],       # DPT1: 8 (don't know), 9 (missing)
    'h51': [8, 9],      # Pentavalent1: 8 (don't know), 9 (missing)
    'v467d': [9],       # Distance barriers: 9 (missing)
    'm15': [99],        # Facility of delivery : 99 (missing)
    'v106': [9],        # Maternal education: 9 (missing)
    'm14': [98, 99]     # Attended ANC >= once: 98 (don't know), 99 (missing)
}

# Standard NDHS clinical facility codes for facility delivery grouping
# (verified against the 2023-24 NDHS recode manual)
CLINICAL_FACILITY_CODES = [
    21, 22, 23, 24, 25, 26, 27,  # Public Sector
    31, 32, 35, 36, 37, 38,      # Private Sector
    41, 42, 46                   # Home / Faith-Based
]

# Design/identifier columns that must never be dropped-for-low-missingness or
# imputed — a missing stratum, cluster, or state code should not be guessed.
DESIGN_AND_ID_COLUMNS = ['caseid', 'v001', 'v002', 'v023', 'v024', 'sstate']

# ==========================================
# PIPELINE MODULES
# ==========================================

def load_raw_data(file_path: Path) -> pd.DataFrame:
    """Safely ingests raw Stata dataset while preserving original numeric encodings."""
    if not file_path.exists():
        raise FileNotFoundError(f"Critical Error: Source file not found at '{file_path}'")

    print(f"[1/7] Ingesting raw stata file: {file_path}...")
    return pd.read_stata(file_path, convert_categoricals=False)


def isolate_cohort(df: pd.DataFrame, zone_col: str, zone_code: int) -> pd.DataFrame:
    """Filters data for the target region and reduces columns to save memory."""
    print(f"[2/7] Subsetting for Geopolitical Zone {zone_code}...")

    if zone_col not in df.columns:
        raise KeyError(f"Geographic column '{zone_col}' is missing from the dataset.")

    filtered_df = df[df[zone_col] == zone_code].copy()

    # Bug Guard 1: Terminate early if the filtered subset is empty
    if len(filtered_df) == 0:
        raise ValueError(
            f"Zero records found matching {zone_col} == {zone_code}. "
            "Please verify the dataset contains valid records for this filter."
        )

    missing_cols = [col for col in ANALYTICAL_COLUMNS if col not in filtered_df.columns]
    if missing_cols:
        raise KeyError(f"The following required variables are missing from the dataset: {missing_cols}")

    return filtered_df[ANALYTICAL_COLUMNS].copy()


def validate_schema(df: pd.DataFrame, schema: dict):
    """Enforces type check constraints dynamically before downstream calculations."""
    print("[3/7] Initiating programmatic schema verification...")

    for col, expected in schema.items():
        # Check if the column actually exists before validating
        if col not in df.columns:
            raise KeyError(f"Validation Failed: Required column '{col}' is missing.")

        if expected == 'numeric':
            if not pd.api.types.is_numeric_dtype(df[col]):
                raise TypeError(f"Validation Failed: Column '{col}' must be numeric.")

        # THIS HANDLES BOTH OLD ('object') AND NEW ('string') PANDAS ENGINES
        elif expected in ('string', 'object'):
            if not pd.api.types.is_string_dtype(df[col]):
                raise TypeError(f"Validation Failed: Column '{col}' must be a string/text type.")

    print("      SUCCESS: Structural schema verification completed.")


def normalize_missing_values(df: pd.DataFrame, missing_map: dict) -> pd.DataFrame:
    """Converts localized survey-specific non-responses into standard NaNs."""
    df_clean = df.copy()
    for col, placeholders in missing_map.items():
        if col not in df_clean.columns:
            print(f"      Warning: Column '{col}' not found in data. Skipping missingness normalization for this variable.")
            continue
        df_clean[col] = df_clean[col].replace(placeholders, np.nan)
    return df_clean


def build_combined_dose1_outcome(df: pd.DataFrame) -> pd.DataFrame:
    """
    NDHS 2018 is a transition-era survey: it carries the legacy DPT1 variable
    (h3) alongside the current Pentavalent1 variable (h51) as two parallel
    fields, because some children's cards were labeled "DPT" and others
    "Pentavalent" depending on when the national schedule switched. A child
    received their first dose of a DTP-containing vaccine if EITHER field
    shows a valid receipt code (1 = card w/ date, 2 = mother's report,
    3 = card marked, no date). The combined outcome is only truly missing if
    BOTH h3 and h51 are unknown (don't know / missing, already mapped to NaN
    by normalize_missing_values) — one source being known is enough to
    classify the child, even if the other source is blank because that
    vaccine name never applied to them.
    """
    df = df.copy()
    received_dpt1 = df['h3'].isin([1, 2, 3])
    received_penta1 = df['h51'].isin([1, 2, 3])
    both_unknown = df['h3'].isna() & df['h51'].isna()

    df['dose1_combined'] = np.where(
        both_unknown, np.nan,
        np.where(received_dpt1 | received_penta1, 1, 0)
    )
    return df


def run_data_integrity_audits(df: pd.DataFrame):
    """Executes clinical-epidemiological safety checks on our baseline cohort."""
    print("[4/7] Running clinical data-integrity audits...")

    # Audit 1: Biological sex ratio balance check
    if len(df) == 0:
        print("      WARNING: Empty dataframe - cannot calculate sex ratio.")
        return

    female_proportion = (df['b4'] == 2).sum() / len(df)
    print(f"      AUDIT -> Calculated female infant proportion: {female_proportion:.4f}")

    if not (0.45 <= female_proportion <= 0.55):
        print("      WARNING!: Skewed biological sex ratio detected. Confirm stratification parameters!")
    else:
        print("      PASS!: Child sex distribution aligns with baseline biological expectations.")

    # Audit 2: Core analytical bounds verification
    if not df['v190'].dropna().isin([1, 2, 3, 4, 5]).all():
        print("     WARNING: Out-of-bounds values found within Wealth Index (v190)!")
    else:
        print("      PASS: Wealth Index values occupy expected [1-5] boundaries.")


def check_for_missingness_bias(df: pd.DataFrame, outcome_col: str, state_col: str, output_path: Path):
    """
    Diagnostic tool to calculate specific drop rates per state.
    """
    print("\n[Audit] Detailed Missingness Report by State...")

    # State mapping dictionary
    state_names = {
        1: "Sokoto", 2: "Zamfara", 3: "Katsina", 4: "Jigawa",
        10: "Kano", 11: "Kaduna", 12: "Kebbi"
    }

    # Use .size() to count ALL rows (including NaNs)
    summary = df.groupby(state_col)[outcome_col].agg(
        total_records='size',
        missing_records=lambda x: x.isnull().sum()
    )

    # Calculate percentage
    summary['missing_percentage'] = (summary['missing_records'] / summary['total_records']) * 100

    # Map the state names to the index for readability
    summary.index = summary.index.map(lambda x: state_names.get(x, f"Unknown({x})"))
    summary.index.name = 'State'

    # Sort and print
    print(summary.sort_values(by='missing_percentage', ascending=False).to_string())

    # Save the audit output as a csv file
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary.to_csv(output_path)
    print(f"\n[Audit] File generated: {output_path}")

    # Threshold check
    max_missing = summary['missing_percentage'].max()
    if max_missing > 5:
        print(f"\n!!! WARNING: High missingness detected in at least one state ({max_missing:.2f}%).")
    else:
        print(f"\nPASS: Missingness is within acceptable bounds (Max: {max_missing:.2f}%).")


def resolve_missingness(df: pd.DataFrame, threshold: float, outcome_col: str) -> pd.DataFrame:
    """
    Implements the epidemiological 5% rule. The drop/impute decision for every
    predictor is made from missingness rates computed ONCE, on the same starting
    dataframe (after the outcome-driven drop) — not recomputed column-by-column
    as rows get removed. This keeps the result independent of column order:
    the same set of predictors is dropped or imputed no matter what sequence
    they're processed in.
    - Drops cases with missing primary outcomes.
    - Drops predictor records if missingness < threshold.
    - Imputes records via median/mode if missingness >= threshold.
    - Design/identifier columns (caseid, cluster, household, strata, zone,
      state) are never dropped-for or imputed — a missing one means the
      record's design info is broken, not something to guess.
    """
    print(f"[5/7] Executing missing data engine (Imputation Threshold: {threshold*100}%)...")
    df_clean = df.copy()

    # Rule 1: The primary clinical outcome cannot be imputed under any condition
    if df_clean[outcome_col].isnull().any():
        initial_count = len(df_clean)
        df_clean = df_clean.dropna(subset=[outcome_col]).copy()
        dropped = initial_count - len(df_clean)
        print(f"      Outcome-driven Drop: Removed {dropped} records with missing primary outcomes.")

    # Rule 2: Decide the full drop/impute plan upfront, from missingness rates
    # computed on this same starting point — order-independent by construction.
    # h3/h51 are excluded alongside the outcome: both raw vaccine-label fields
    # are already fully consumed into the combined outcome column, so treating
    # either as a leftover "predictor" needing its own drop/impute pass would
    # discard records that are perfectly valid under the combined definition.
    excluded_cols = DESIGN_AND_ID_COLUMNS + [outcome_col, 'h3', 'h51']
    predictors = [col for col in df_clean.columns if col not in excluded_cols]

    missing_rates = {col: df_clean[col].isnull().mean() for col in predictors}
    drop_cols = [col for col, rate in missing_rates.items() if 0 < rate < threshold]
    impute_cols = [col for col, rate in missing_rates.items() if rate >= threshold]

    # Apply all low-missingness drops in a single combined pass
    if drop_cols:
        before = len(df_clean)
        df_clean = df_clean.dropna(subset=drop_cols).copy()
        for col in drop_cols:
            print(f"      Low Missingness (< {threshold*100}%): '{col}' included in combined drop (Rate: {missing_rates[col]:.2%}).")
        print(f"      Combined Drop: Removed {before - len(df_clean)} records across {len(drop_cols)} low-missingness column(s).")

    # Apply imputation for high-missingness columns
    for col in impute_cols:
        print(f"      High Missingness (>= {threshold*100}%): Imputing '{col}' (Rate: {missing_rates[col]:.2%})...")

        # Use mode for variables with limited discrete integer options
        if df_clean[col].nunique() < 10:
            modes = df_clean[col].mode()
            # Bug Guard 2: Ensure mode calculation returned values (is not completely empty)
            if not modes.empty:
                mode_val = modes[0]
                df_clean[col] = df_clean[col].fillna(mode_val)
            else:
                print(f"      Warning: Column '{col}' contains only NaN values. Mode imputation skipped.")
        else:
            median_val = df_clean[col].median()
            # Check if median is NaN (all values were NaN)
            if pd.isna(median_val):
                print(f"      Warning: Column '{col}' contains all NaN values. Imputation skipped.")
            else:
                df_clean[col] = df_clean[col].fillna(median_val)

    return df_clean


def transform_and_engineer(df: pd.DataFrame, apply_engineering: bool = True) -> pd.DataFrame:
    """Executes demographic mapping and converts raw features into clean indicators.
    When `apply_engineering` is False the function will only sanitize age (`b8`) and restrict to the target 12-23 month cohort (b8 == 1) only.
    """
    print("[6/7] Transforming features, auditing age(`b8`), and applying 12-23 month filter...")

    # Operate on a copy to avoid side-effects
    df = df.copy()

    # 1. Sanitize 'b8' (Age in years) before filtering
    # Valid codes in DHS are 0, 1, 2, 3, 4. Everything else is irregular.
    valid_ages = [0, 1, 2, 3, 4]
    invalid_mask = ~df['b8'].isin(valid_ages)

    # Audit for Age Data Quality
    irregular_rate = invalid_mask.mean()
    print(f"      [Audit] Irregular age(`b8`) values found: {irregular_rate:.2%}")

    # Force irregular values to NaN so they don't corrupt the analysis
    df.loc[invalid_mask, 'b8'] = np.nan

    # 2. Applying the Age Filter (Targeting 12-23 months / Code 1)
    # NaN values will be excluded by this filter automatically
    df_final = df[df['b8'] == 1].copy()

    # Bug Guard 3: Ensure age filter didn't eliminate all records
    if len(df_final) == 0:
        raise ValueError(
            "Age filter (b8 == 1 for 12-23 months) resulted in zero records. "
            "Please verify the dataset contains valid age codes."
        )

    # If caller only wants to apply the age filter (for missingness checks), return now
    if not apply_engineering:
        return df_final

    # 3. Post-cleaning integrity check: Ensure no missing values remains in required columns
    # h3/h51 are excluded individually: a child can legitimately have one blank
    # (the vaccine name that never applied to their card) while the other is
    # known. What must be non-missing is the combined outcome, 'dose1_combined',
    # which resolve_missingness() already enforced via Rule 1.
    required_vars = [
        c for c in ANALYTICAL_COLUMNS
        if c not in ['caseid', 'v001', 'v002', 'v024', 'sstate', 'b8', 'h3', 'h51']
    ]
    missing_after_cleaning = [
        var for var in required_vars
        if df_final[var].isna().any()
    ]

    if missing_after_cleaning:
        raise ValueError(
            f"Unexpected missing values remain after missing-data resolution: {missing_after_cleaning}"
        )
    print("      PASS: No missing values remain in analytical variables.")

    # 3. Binary variables transformation
    # is_zero_dose is the inverse of the combined DPT1/Penta1 receipt indicator
    # built in build_combined_dose1_outcome() (1 = received dose 1 by either
    # label -> 0 = not zero-dose; 0 = received neither -> 1 = zero-dose).
    df_final['is_zero_dose'] = (df_final['dose1_combined'] == 0).astype(int)
    df_final['is_rural'] = (df_final['v025'] == 2).astype(int)
    df_final['distance_barrier'] = (df_final['v467d'] == 1).astype(int)
    df_final['is_female'] = (df_final['b4'] == 2).astype(int)
    df_final['facility_delivery'] = df_final['m15'].isin(CLINICAL_FACILITY_CODES).astype(int)
    df_final['received_anc'] = (df_final['m14'] > 0).astype(int)

    # 4. Normalize complex survey weight variables
    df_final['sample_weight'] = df_final['v005'] / 1000000

    # 5. Final selection (Ensuring 'b8' is kept for future reference)
    target_columns = [
        'caseid',
        'v001',
        'v002',
        'v023',
        'v024',
        'sstate',
        'sample_weight',
        'is_zero_dose',
        'v106', 'v190',
        'is_rural',
        'distance_barrier',
        'facility_delivery',
        'received_anc',
        'is_female',
        'b8'
    ]
    df_final = df_final[target_columns].copy()

    # 6. Rename and map labels
    df_final.rename(columns={
        'v106': 'maternal_education',
        'v190': 'wealth_index',
        'sstate': 'state_code'
    }, inplace=True)

    education_labels = {
        0: "No Education",
        1: "Primary",
        2: "Secondary",
        3: "Higher"}

    df_final['maternal_education'] = df_final['maternal_education'].map(education_labels)
    # Check for unmapped values
    if df_final['maternal_education'].isnull().sum() > 0:
        print(f"      Warning: {df_final['maternal_education'].isnull().sum()} records have unmapped maternal education values.")
        raise ValueError("Unexpected maternal education codes detected.")

    wealth_labels = {1: "Poorest", 2: "Poorer", 3: "Middle", 4: "Richer", 5: "Richest"}
    df_final['wealth_index'] = df_final['wealth_index'].map(wealth_labels)
    # Check for unmapped values
    if df_final['wealth_index'].isnull().sum() > 0:
        print(f"      Warning: {df_final['wealth_index'].isnull().sum()} records have unmapped wealth index values.")
        raise ValueError("Unexpected wealth index codes detected.")

    state_names = {
        1: "Sokoto", 2: "Zamfara", 3: "Katsina", 4: "Jigawa",
        10: "Kano", 11: "Kaduna", 12: "Kebbi"
    }
    df_final['state_code'] = df_final['state_code'].map(state_names)
    # Check for unmapped values
    if df_final['state_code'].isnull().sum() > 0:
        print(f"      Warning: {df_final['state_code'].isnull().sum()} records have unmapped state codes.")
        raise ValueError("Unexpected state codes detected.")

    return df_final


def export_clean_contract(df: pd.DataFrame, output_path: Path):
    """Writes the finalized, frozen analytic cohort directly to storage."""
    print(f"[7/7] Locking analytic contract in storage...")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_path, index=False)
    print(f"      SUCCESS: Clean analytical file generated: '{output_path}' ({len(df)} records).")


# ==========================================
# MAIN EXECUTION INTERFACE
# ==========================================

def run_pipeline(input_file: Path, output_file: Path, audit_file: Path, missing_threshold: float = 0.05):
    """Executes the complete ETL sequence linearly under safe error handling."""
    try:
        raw_data = load_raw_data(input_file)

        northwest_cohort = isolate_cohort(raw_data, zone_col='v024', zone_code=1)

        validate_schema(northwest_cohort, SCHEMA_EXPECTED_TYPES)

        normalized_cohort = normalize_missing_values(northwest_cohort, MISSINGNESS_MAP)

        run_data_integrity_audits(normalized_cohort)

        analytic_age_cohort = transform_and_engineer(normalized_cohort, apply_engineering=False)

        analytic_age_cohort = build_combined_dose1_outcome(analytic_age_cohort)

        check_for_missingness_bias(analytic_age_cohort, outcome_col='dose1_combined', state_col='sstate', output_path=audit_file)

        resolved_cohort = resolve_missingness(analytic_age_cohort, threshold=missing_threshold, outcome_col='dose1_combined')

        clean_analytic_file = transform_and_engineer(resolved_cohort, apply_engineering=True)

        export_clean_contract(clean_analytic_file, output_file)

        print("\n SUCCESS! PIPELINE EXECUTED COMPLETELY.")

    except Exception as error:
        print(f"\n PIPELINE CRASHED: {str(error)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    run_pipeline(
        input_file=INPUT_DTA,
        output_file=OUTPUT_CSV,
        audit_file=AUDIT_CSV,
        missing_threshold=0.05
    )
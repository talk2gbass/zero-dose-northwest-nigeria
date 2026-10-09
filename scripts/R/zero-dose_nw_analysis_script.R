# ==============================================================================
# SURVEY-WEIGHTED EPIDEMIOLOGICAL PIPELINE FOR COMPLEX SURVEY DESIGNS
# Project: Predictors of Zero-Dose Status among Children in Northwest Nigeria
# Target Cohort: NDHS Cleaned Analytic Contract File
# Language: R Version 4.5.3+
# Author: Jibrin Godwin
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT SETTINGS & COMPREHENSIVE DEPENDENCY MANAGEMENT
# ------------------------------------------------------------------------------
options(timeout = 600)

required_packages <- c(
  "survey", "srvyr", "gt", "gtsummary", "dplyr",
  "ggplot2", "scales", "officer", "flextable", "here", "sf", "tibble"
)

missing_packages <- required_packages[!(required_packages %in% installed.packages()[, "Package"])]

if (length(missing_packages) > 0) {
  message("Package check failed: Missing libraries detected. Initiating CRAN downloads...")
  options(repos = c(CRAN = "https://cloud.r-project.org"))
  install.packages(missing_packages, dependencies = TRUE)
  message("All dependencies successfully retrieved and compiled.")
} else {
  message("System Check: All analytical frameworks are already installed and up-to-date.")
}

invisible(lapply(required_packages, library, character.only = TRUE))

# 1.1 DATA LOADING
# Path matches the project schema: data/processed/zero-dose_nw_cleaned_data.csv
nw_raw <- read.csv(here("data", "processed", "zero-dose_nw_cleaned_data.csv"))
message("Data successfully loaded into memory.")

# 1.2 OUTPUT DIRECTORY STRUCTURE (REPRODUCIBLE RESEARCH PIPELINE)
dir.create(here("outputs"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("outputs", "tables"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("outputs", "figures"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("outputs", "gis"), recursive = TRUE, showWarnings = FALSE)
dir.create(here("outputs", "powerbi"), recursive = TRUE, showWarnings = FALSE)
message("Output directory structure initialized successfully.")

#-------------------------------------------------------------------------------
# 2. INGESTION & TYPE COERCION
#-------------------------------------------------------------------------------
nw_data <- nw_raw %>%
  mutate(
    # Force outcome to clean integers (0 or 1) to satisfy GLM requirements
    is_zero_dose = as.integer(as.character(is_zero_dose)),

    # Keep factor for table display (unchanged)
    is_zero_dose_factor = factor(
      is_zero_dose,
      levels = c(0, 1),
      labels = c("Vaccinated", "Zero-Dose")
    ),
    maternal_education = factor(
      maternal_education,
      levels = c("No Education", "Primary", "Secondary", "Higher")
    ),
    wealth_index = factor(
      wealth_index,
      levels = c("Poorest", "Poorer", "Middle", "Richer", "Richest")
    ),
    state_code = factor(state_code),
    is_rural = factor(
      is_rural,
      levels = c(0, 1),
      labels = c("Urban", "Rural")
    ),
    distance_barrier = factor(
      distance_barrier,
      levels = c(0, 1),
      labels = c("No Barrier", "Barrier")
    ),
    facility_delivery = factor(
      facility_delivery,
      levels = c(0, 1),
      labels = c("Home/Other", "Clinical Facility")
    ),
    received_anc = factor(
      received_anc,
      levels = c(0, 1),
      labels = c("No ANC", "Received ANC")
    ),
    is_female = factor(
      is_female,
      levels = c(0, 1),
      labels = c("Male", "Female")
    )
  )

# ------------------------------------------------------------------------------
# 3. COMPLEX SURVEY DESIGN SPECIFICATION
# ------------------------------------------------------------------------------
# DHS METHODOLOGY: Set lonely PSU handling BEFORE design object creation for proper initialization
options(survey.lonely.psu = "adjust")

message("Constructing survey design object...")
nw_survey_design <- svydesign(
  ids = ~v001,
  strata = ~v023,
  weights = ~sample_weight,
  data = nw_data,
  nest = TRUE
)

# QA: SURVEY DESIGN INTEGRITY VALIDATION (DHS METHODOLOGY STANDARD)
# Verify survey design object initialization succeeded
if (!inherits(nw_survey_design, "survey.design")) {
  stop("Survey design object initialization failed. Check data types and design parameters.")
}

# Verify all survey weights are positive (required for design-based inference)
if (any(nw_data$sample_weight <= 0, na.rm = TRUE)) {
  warning("Survey design: non-positive weights detected. Review data quality and weight calculation.")
}

# Verify no missing strata codes (required for proper variance estimation and stratified analysis)
if (any(is.na(nw_data$v023))) {
  warning("Survey design: observations with missing strata codes detected. May affect variance estimates.")
}

message("QA: Survey design object validated successfully. Ready for design-based inference.")

# ------------------------------------------------------------------------------
# 4. TABLE 1: WEIGHTED DESCRIPTIVE CHARACTERISTICS
# ------------------------------------------------------------------------------
message("Rendering weighted epidemiological Table 1...")

weighted_table1 <- nw_survey_design %>%
  tbl_svysummary(
    by = is_zero_dose_factor,
    include = c(maternal_education, wealth_index, is_rural, distance_barrier, facility_delivery, received_anc, is_female, state_code),
    label = list(
      maternal_education ~ "Maternal Education",
      wealth_index ~ "Household Wealth Quintile",
      is_rural ~ "Residential Locality",
      distance_barrier ~ "Distance to Health Facility",
      facility_delivery ~ "Place of Delivery",
      received_anc ~ "Antenatal Care",
      is_female ~ "Child Sex",
      state_code ~ "State"
    ),
    statistic = list(all_categorical() ~ "{n_unweighted} ({p}%)"),
    percent = "column"
  ) %>%
  add_p() %>%
  bold_labels() %>%
  modify_header(label = "**Socio-demographic characteristics**")

# 4.1 EXPORT TABLE 1: WORD DOCUMENT FORMAT
# Convert gtsummary object to flextable for Word export (preserves exact formatting)
weighted_table1_ft <- weighted_table1 %>%
  as_flex_table()

save_as_docx(weighted_table1_ft, path = here("outputs", "tables", "Table_1_Weighted_Characteristics.docx"))
message("SUCCESS: Table 1 Word exported.")

# 4.2 EXPORT TABLE 1: CSV FORMAT
header <- weighted_table1$table_styling$header
header_labels <- header$label
names(header_labels) <- header$column
header_labels <- gsub("\\*\\*", "", header_labels)
header_labels <- gsub("\n", " ", header_labels)

weighted_table1_data <- weighted_table1$table_body %>%
  select(label, starts_with("stat_"), p.value) %>%
  rename(
    Characteristics = label,
    P_Value = p.value
  )

names(weighted_table1_data) <- ifelse(
  names(weighted_table1_data) %in% names(header_labels),
  header_labels[names(weighted_table1_data)],
  names(weighted_table1_data)
)

col_names <- names(weighted_table1_data)
stat_cols <- grep("Vaccinated|Zero-Dose", col_names, value = TRUE)

for (col in stat_cols) {
  n_col_name <- paste0(col, " (N)")
  pct_col_name <- paste0(col, " (%)")

  weighted_table1_data[[n_col_name]] <- sub("\\s*\\(.*\\)", "", weighted_table1_data[[col]])
  weighted_table1_data[[pct_col_name]] <- sub(".*\\((.*)%\\)", "\\1", weighted_table1_data[[col]])

  weighted_table1_data[[n_col_name]] <- ifelse(grepl("\\(", weighted_table1_data[[col]]), weighted_table1_data[[n_col_name]], weighted_table1_data[[col]])
  weighted_table1_data[[pct_col_name]] <- ifelse(grepl("\\(", weighted_table1_data[[col]]), weighted_table1_data[[pct_col_name]], "")
}

# Create Category column for CSV
csv_table1_data <- weighted_table1_data

category_rows <- which(
  trimws(csv_table1_data$Characteristics) %in% c(
    "Maternal Education",
    "Household Wealth Quintile",
    "Residential Locality",
    "Distance to Health Facility",
    "Place of Delivery",
    "Antenatal Care",
    "Child Sex",
    "State"
  )
)

csv_table1_data$Category <- trimws(csv_table1_data$Characteristics)

csv_table1_data$Characteristics <- ifelse(
  seq_len(nrow(csv_table1_data)) %in% category_rows,
  trimws(csv_table1_data$Characteristics),
  ""
)

csv_table1_data$Category[seq_len(nrow(csv_table1_data)) %in% category_rows] <- ""

# Fill down Characteristics and P_Value to ensure no empty cells
for (i in seq_len(nrow(csv_table1_data))) {
  if (i > 1) {
    if (is.na(csv_table1_data$Characteristics[i]) || csv_table1_data$Characteristics[i] == "") {
      csv_table1_data$Characteristics[i] <- csv_table1_data$Characteristics[i - 1]
    }
    if (is.na(csv_table1_data$P_Value[i]) || csv_table1_data$P_Value[i] == "" || csv_table1_data$P_Value[i] == "—") {
      csv_table1_data$P_Value[i] <- csv_table1_data$P_Value[i - 1]
    }
  }
}

# Drop redundant category-header rows now that Characteristics has been filled down to every level row
csv_table1_data <- csv_table1_data[!(seq_len(nrow(csv_table1_data)) %in% category_rows), ]

# Arrange CSV columns
other_cols <- setdiff(names(csv_table1_data), c("Characteristics", "Category"))
csv_table1_data <- csv_table1_data[, c("Characteristics", "Category", other_cols)]

write.csv(
  csv_table1_data,
  file = here("outputs", "tables", "Table_1_Weighted_Characteristics.csv"),
  row.names = FALSE,
  na = ""
)

message("SUCCESS: Table 1 CSV exported.")

# ------------------------------------------------------------------------------
# 5. MULTIVARIATE LOGISTIC REGRESSION (aOR ESTIMATES)
# ------------------------------------------------------------------------------
message("Estimating Pseudo-Maximum Likelihood logistic regression coefficients...")

zero_dose_model <- svyglm(
  is_zero_dose ~ maternal_education + wealth_index + is_rural + distance_barrier + facility_delivery + received_anc + is_female,
  design = nw_survey_design,
  family = quasibinomial(link = "logit")
)

regression_results <- zero_dose_model %>%
  tbl_regression(
    exponentiate = TRUE,
    label = list(
      maternal_education ~ "Maternal Education Level",
      wealth_index ~ "Household Wealth Quintile",
      is_rural ~ "Residential Locality",
      distance_barrier ~ "Physical Barrier (Distance to Health Facility)",
      facility_delivery ~ "Clinical Care at Delivery",
      received_anc ~ "Received Antenatal Care (ANC)",
      is_female ~ "Child Sex"
    )
  ) %>%
  bold_p(t = 0.05) %>%
  italicize_levels()

print(regression_results)


# ------------------------------------------------------------------------------
# 6. TABLE2 EXTRACTOR (DYNAMIC EXPORT TO MS WORD & CSV)
# ------------------------------------------------------------------------------
message("Extracting survey regression model statistics to Word document...")

model_summary <- summary(zero_dose_model)
coef_matrix <- model_summary$coefficients
ci_matrix <- confint(zero_dose_model)

est <- coef_matrix[, 1]
p_vals <- coef_matrix[, 4]

find_coef_stats <- function(exact_name) {
  idx <- which(names(est) == exact_name)
  if (length(idx) == 0) {
    return(list(or = "—", ci = "—", p = "—"))
  }
  if (length(idx) > 1) stop(paste("Duplicate coefficient name:", exact_name))

  or_val <- exp(est[idx])
  lo_val <- exp(ci_matrix[idx, 1])
  up_val <- exp(ci_matrix[idx, 2])
  p_val <- p_vals[idx]

  list(
    or = sprintf("%.2f", or_val),
    ci = sprintf("%.2f — %.2f", lo_val, up_val),
    p  = if (p_val < 0.001) "<0.001" else sprintf("%.3f", p_val)
  )
}
p_edu <- find_coef_stats("maternal_educationPrimary")
s_edu <- find_coef_stats("maternal_educationSecondary")
h_edu <- find_coef_stats("maternal_educationHigher")
poo_w <- find_coef_stats("wealth_indexPoorer")
mid_w <- find_coef_stats("wealth_indexMiddle")
ric_w <- find_coef_stats("wealth_indexRicher")
rcst_w <- find_coef_stats("wealth_indexRichest")
rur_loc <- find_coef_stats("is_ruralRural")
dist_bar <- find_coef_stats("distance_barrierBarrier")
fac_del <- find_coef_stats("facility_deliveryClinical Facility")
anc <- find_coef_stats("received_ancReceived ANC")
fem_ch <- find_coef_stats("is_femaleFemale")

table_data <- data.frame(
  Characteristics = c(
    "Maternal Education Level", "  No Education (Reference)", "  Primary Education", "  Secondary Education", "  Higher Education",
    "Wealth Index Quintile", "  Poorest (Reference)", "  Poorer", "  Middle", "  Richer", "  Richest",
    "Locality Type", "  Urban (Reference)", "  Rural Locality",
    "Physical Barrier (Distance to Health Facility)", "  No Barrier (Reference)", "  Barrier",
    "Clinical Care at Delivery", "  Home/Other (Reference)", "  Clinical Facility",
    "Received Antenatal Care (ANC)", "No ANC (Reference)", "Received ANC",
    "Gender of Child", "  Male (Reference)", " Female Child"
  ),
  aOR = c(
    "", "1.00 (Ref.)", p_edu$or, s_edu$or, h_edu$or,
    "", "1.00 (Ref.)", poo_w$or, mid_w$or, ric_w$or, rcst_w$or,
    "", "1.00 (Ref.)", rur_loc$or,
    "", "1.00 (Ref.)", dist_bar$or,
    "", "1.00 (Ref.)", fac_del$or,
    "", "1.00 (Ref.)", anc$or,
    "", "1.00 (Ref.)", fem_ch$or
  ),
  CI_95 = c(
    "", "—", p_edu$ci, s_edu$ci, h_edu$ci,
    "", "—", poo_w$ci, mid_w$ci, ric_w$ci, rcst_w$ci,
    "", "—", rur_loc$ci,
    "", "—", dist_bar$ci,
    "", "—", fac_del$ci,
    "", "—", anc$ci,
    "", "—", fem_ch$ci
  ),
  P_Value = c(
    "", "—", p_edu$p, s_edu$p, h_edu$p,
    "", "—", poo_w$p, mid_w$p, ric_w$p, rcst_w$p,
    "", "—", rur_loc$p,
    "", "—", dist_bar$p,
    "", "—", fac_del$p,
    "", "—", anc$p,
    "", "—", fem_ch$p
  ),
  stringsAsFactors = FALSE
)

ft <- flextable(table_data) %>%
  set_header_labels(
    Characteristics = "Characteristics / Predictor Variables",
    aOR = "Adjusted Odds Ratio (aOR)",
    CI_95 = "95% Confidence Interval (CI)",
    P_Value = "p-value"
  ) %>%
  align(j = 2:4, align = "center", part = "all") %>%
  padding(padding = 5, part = "all") %>%
  font(fontname = "Times New Roman", part = "all") %>%
  fontsize(size = 11, part = "all") %>%
  border_remove() %>%
  hline_top(border = fp_border(color = "black", width = 1.5)) %>%
  hline_bottom(border = fp_border(color = "black", width = 1.5)) %>%
  hline(i = 1, border = fp_border(color = "gray80", width = 0.5)) %>%
  bold(part = "header") %>%
  bold(i = c(1, 6, 12, 15, 18, 21, 24)) %>%
  padding(j = 1, i = c(2:5, 7:11, 13:14, 16:17, 19:20, 22:23, 25:26), padding.left = 15) %>%
  autofit()

# 6.1 EXPORT TABLE 2: WORD FORMAT
save_as_docx(ft, path = here("outputs", "tables", "Table_2_Zero_Dose_Regression_Results.docx"))
message("SUCCESS: Table 2 Word exported.")

# 6.2 EXPORT TABLE 2: CSV FORMAT
ci_split <- t(sapply(as.character(table_data$CI_95), function(x) {
  if (grepl(" — ", x, fixed = TRUE)) {
    strsplit(x, " — ", fixed = TRUE)[[1]]
  } else {
    c("", "")
  }
}))
table_data$`Lower CI_95` <- ci_split[, 1]
table_data$`Upper CI_95` <- ci_split[, 2]

ci_col_pos <- which(names(table_data) == "CI_95")
table_data <- table_data[, c(1:(ci_col_pos - 1), ci_col_pos, match("Lower CI_95", names(table_data)), match("Upper CI_95", names(table_data)), (ci_col_pos + 1):(ncol(table_data) - 2))]

# Create Category column for CSV only
csv_table_data <- table_data

category_rows <- c(1, 6, 12, 15, 18, 21, 24)

csv_table_data$Category <- trimws(csv_table_data$Characteristics)

csv_table_data$Characteristics <- ifelse(
  seq_len(nrow(csv_table_data)) %in% category_rows,
  trimws(csv_table_data$Characteristics),
  ""
)

csv_table_data$Category[seq_len(nrow(csv_table_data)) %in% category_rows] <- ""

# Fill down Characteristics so every row documents its predictor group, not just the header row
for (i in seq_len(nrow(csv_table_data))) {
  if (i > 1 && csv_table_data$Characteristics[i] == "") {
    csv_table_data$Characteristics[i] <- csv_table_data$Characteristics[i - 1]
  }
}

# Drop the now-redundant category-header rows (Characteristics is carried on every data row already)
csv_table_data <- csv_table_data[!(seq_len(nrow(csv_table_data)) %in% category_rows), ]

# Reference-category rows (aOR = 1.00) have no valid CI or p-value to report, since nothing is
# being tested against itself. Label them explicitly as "Reference" instead of leaving the cell
# blank or writing NA, so no cell is empty and no value is misread as missing data.
ref_rows <- csv_table_data$aOR == "1.00 (Ref.)"
csv_table_data$CI_95[ref_rows] <- "Reference"
csv_table_data$`Lower CI_95`[ref_rows] <- "Reference"
csv_table_data$`Upper CI_95`[ref_rows] <- "Reference"
csv_table_data$P_Value[ref_rows] <- "Reference"

# Arrange CSV columns
csv_table_data <- csv_table_data[, c(
  "Characteristics",
  "Category",
  "aOR",
  "CI_95",
  "Lower CI_95",
  "Upper CI_95",
  "P_Value"
)]

write.csv(
  csv_table_data,
  file = here("outputs", "tables", "Table_2_Zero_Dose_Regression_Results.csv"),
  row.names = FALSE,
  na = "",
  fileEncoding = "UTF-8"
)
message("SUCCESS: Table 2 CSV exported.")

# ------------------------------------------------------------------------------
# 6.3 MASTER COEFFICIENT LOOKUP + CSV FILES FOR POWER BI EXPORTS
# ------------------------------------------------------------------------------
# Single source of truth for readable labels: used by prev_long below, by
# forest_pbi below, AND by Figure 1's forest plot in Section 7. Editing a
# label here updates it everywhere at once, so the Power BI exports and the
# Word/PNG report outputs can never drift out of sync again.
label_lookup <- c(
  maternal_education = "Maternal Education Level",
  wealth_index = "Household Wealth Quintile",
  is_rural = "Residential Locality",
  distance_barrier = "Physical Barrier (Distance to Health Facility)",
  facility_delivery = "Clinical Care at Delivery",
  received_anc = "Received Antenatal Care (ANC)",
  is_female = "Gender of Child",
  state_code = "State"
)

vars <- c(
  "maternal_education", "wealth_index", "is_rural", "distance_barrier",
  "facility_delivery", "received_anc", "is_female", "state_code"
)

prev_long <- lapply(vars, function(v) {
  nw_survey_design %>%
    as_survey() %>%
    group_by(Category = .data[[v]]) %>%
    summarize(
      zero_dose_pct = survey_mean(is_zero_dose, vartype = "ci") * 100,
      n = unweighted(n())
    ) %>%
    mutate(
      Category = as.character(Category),
      Characteristic = label_lookup[[v]], # readable label, not raw variable name
      .before = 1
    )
}) %>% bind_rows()

write.csv(prev_long, here("outputs", "powerbi", "prevalence_by_characteristic.csv"),
  row.names = FALSE
)

# Maps each exact svyglm coefficient name to its readable Characteristic +
# Category (plain, used by Power BI slicers/axes) AND a report_label with
# full "vs reference" wording (used by Figure 1's forest plot, and optionally
# by a standalone Power BI forest plot that should read like Figure 1).
coef_lookup <- tibble::tribble(
  ~coef_name, ~var_name, ~Category, ~report_label,
  "maternal_educationPrimary", "maternal_education", "Primary", "Maternal Education: Primary (vs No Edu)",
  "maternal_educationSecondary", "maternal_education", "Secondary", "Maternal Education: Secondary (vs No Edu)",
  "maternal_educationHigher", "maternal_education", "Higher", "Maternal Education: Higher (vs No Edu)",
  "wealth_indexPoorer", "wealth_index", "Poorer", "Wealth Quintile: Poorer (vs Poorest)",
  "wealth_indexMiddle", "wealth_index", "Middle", "Wealth Quintile: Middle (vs Poorest)",
  "wealth_indexRicher", "wealth_index", "Richer", "Wealth Quintile: Richer (vs Poorest)",
  "wealth_indexRichest", "wealth_index", "Richest", "Wealth Quintile: Richest (vs Poorest)",
  "is_ruralRural", "is_rural", "Rural", "Rural Locality (vs Urban)",
  "distance_barrierBarrier", "distance_barrier", "Barrier", "Distance to Facility: Barrier (vs No Barrier)",
  "facility_deliveryClinical Facility", "facility_delivery", "Clinical Facility", "Clinical Facility Delivery (vs Home/Other)",
  "received_ancReceived ANC", "received_anc", "Received ANC", "Received ANC (vs No ANC)",
  "is_femaleFemale", "is_female", "Female", "Female Child (vs Male)"
) %>%
  mutate(Characteristics = label_lookup[var_name])

# Built directly from the model (est / ci_matrix), NOT from csv_table_data,
# so its Characteristics/Category text always matches prev_long's exactly.
forest_pbi <- coef_lookup %>%
  rowwise() %>%
  mutate(
    aOR   = exp(est[[coef_name]]),
    Lower = exp(ci_matrix[coef_name, 1]),
    Upper = exp(ci_matrix[coef_name, 2])
  ) %>%
  ungroup() %>%
  select(Characteristics, Category, report_label, aOR, Lower, Upper)

write.csv(forest_pbi, here("outputs", "powerbi", "forest_plot_data.csv"), row.names = FALSE)

message("SUCCESS: CSV files for Power BI exported.")
# ------------------------------------------------------------------------------
# 7. FIGURE 1: FOREST PLOT
# ------------------------------------------------------------------------------
message("Generating Figure 1: Forest Plot...")

forest_data <- data.frame(
  Predictor = names(est),
  aOR = exp(est),
  Lower = exp(ci_matrix[, 1]),
  Upper = exp(ci_matrix[, 2])
)

forest_data <- forest_data[forest_data$Predictor != "(Intercept)", ]

forest_data$CleanLabel <- coef_lookup$report_label[
  match(forest_data$Predictor, coef_lookup$coef_name)
]

unmapped_predictors <- forest_data$Predictor[is.na(forest_data$CleanLabel)]
if (length(unmapped_predictors) > 0) {
  warning(sprintf(
    "Forest plot: unmapped coefficient(s) detected: %s. Add to coef_lookup table.",
    paste(unmapped_predictors, collapse = ", ")
  ))
}

logical_order <- c(
  "Female Child (vs Male)",
  "Received ANC (vs No ANC)",
  "Clinical Facility Delivery (vs Home/Other)",
  "Distance to Facility: Barrier (vs No Barrier)",
  "Rural Locality (vs Urban)",
  "Wealth Quintile: Richest (vs Poorest)",
  "Wealth Quintile: Richer (vs Poorest)",
  "Wealth Quintile: Middle (vs Poorest)",
  "Wealth Quintile: Poorer (vs Poorest)",
  "Maternal Education: Higher (vs No Edu)",
  "Maternal Education: Secondary (vs No Edu)",
  "Maternal Education: Primary (vs No Edu)"
)

forest_data$CleanLabel <- factor(forest_data$CleanLabel, levels = logical_order)

forest_data$TextLabel <- sprintf("%.2f (%.2f, %.2f)", forest_data$aOR, forest_data$Lower, forest_data$Upper)

forest_plot <- ggplot(forest_data, aes(x = CleanLabel, y = aOR)) +
  geom_vline(xintercept = 1:12, color = "gray96", linewidth = 0.5) +
  geom_hline(yintercept = 1.0, linetype = "dashed", color = "#d9534f", linewidth = 0.9) +
  geom_errorbar(aes(ymin = Lower, ymax = Upper), width = 0.22, color = "#2c3e50", linewidth = 0.8) +
  geom_point(color = "#1f4e78", size = 3.5) +
  geom_text(aes(y = 3.8, label = TextLabel), hjust = 0, size = 3.3, fontface = "bold", color = "gray25") +
  coord_flip() +
  scale_y_log10(
    limits = c(0.07, 6.0),
    breaks = c(0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0)
  ) +
  labs(
    title = "Multivariate Adjusted Odds Ratios (aOR) for Zero-Dose Status",
    subtitle = "Survey-Weighted Logistic Regression (Northwest Nigeria Sub-Cohort)",
    x = "Sociodemographic & Obstetric Predictors",
    y = "Adjusted Odds Ratio (Log Scale with 95% CI)"
  ) +
  annotate("text", x = 12.5, y = 0.35, label = "<-- Decreased Odds (Protective)", color = "#2e7d32", size = 3.0, fontface = "bold") +
  annotate("text", x = 12.5, y = 1.45, label = "Increased Odds (Risk) -->", color = "#c62828", size = 3.0, fontface = "bold") +
  annotate("text", x = 12.5, y = 3.80, label = "aOR (95% CI)", color = "black", size = 3.2, fontface = "bold") +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold", size = 13, color = "#1f4e78", margin = margin(b = 6)),
    plot.subtitle = element_text(face = "italic", size = 10, color = "gray30", margin = margin(b = 15)),
    axis.title.x = element_text(face = "bold", margin = margin(t = 12)),
    axis.title.y = element_text(face = "bold", margin = margin(r = 15)),
    axis.text.y = element_text(face = "bold", color = "gray20", size = 9),
    axis.text.x = element_text(face = "bold", color = "gray25"),
    panel.grid.major.x = element_line(color = "gray88", linetype = "dashed", linewidth = 0.5),
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    panel.border = element_rect(color = "gray80", fill = NA, linewidth = 0.5)
  )

ggsave(here("outputs", "figures", "Figure_1_Forest_Plot.png"), plot = forest_plot, width = 11.5, height = 6.5, dpi = 300)
message("SUCCESS: Figure 1 saved.")


# ------------------------------------------------------------------------------
# 8. FIGURE 2: COMPOUND VULNERABILITY SPECTRUM
# ------------------------------------------------------------------------------
message("Generating Figure 2: Vulnerability Spectrum...")

persona_profiles <- data.frame(
  maternal_education = factor(c("Higher", "Higher", "No Education", "No Education"),
    levels = c("No Education", "Primary", "Secondary", "Higher")
  ),
  wealth_index = factor(c("Richest", "Poorest", "Poorest", "Poorest"),
    levels = c("Poorest", "Poorer", "Middle", "Richer", "Richest")
  ),
  is_rural = factor(c("Urban", "Rural", "Rural", "Rural"),
    levels = c("Urban", "Rural")
  ),
  distance_barrier = factor(c("No Barrier", "No Barrier", "No Barrier", "Barrier"),
    levels = c("No Barrier", "Barrier")
  ),
  facility_delivery = factor(c("Clinical Facility", "Clinical Facility", "Clinical Facility", "Home/Other"),
    levels = c("Home/Other", "Clinical Facility")
  ),
  received_anc = factor(c("Received ANC", "Received ANC", "No ANC", "No ANC"),
    levels = c("No ANC", "Received ANC")
  ),
  is_female = factor(c("Female", "Female", "Female", "Female"),
    levels = c("Male", "Female")
  ),
  PersonaName = c(
    "1. Advantaged Baseline\n(Urban, Richest, Higher Education, \nNo Barrier, Received ANC, \nFacility Delivery)",
    "2. Simple Rural Disadvantage\n(Rural, Poorest, Higher Education, \nNo Barrier, Received ANC, \nFacility Delivery)",
    "3. Compounded Social Exclusion\n(Rural, Poorest, No Education, \nNo Barrier, Received ANC, \nFacility Delivery)",
    "4. Triple Jeopardy\n(Rural, Poorest, No Education, \nBarrier, No ANC, \nHome/Other)"
  )
)

predictions <- predict(zero_dose_model, newdata = persona_profiles, type = "response")
persona_profiles$Probability <- as.vector(predictions)

risk_plot <- ggplot(persona_profiles, aes(x = reorder(PersonaName, Probability), y = Probability * 100)) +
  geom_bar(stat = "identity", aes(fill = Probability), width = 0.52, show.legend = FALSE) +
  geom_text(aes(label = sprintf("%.1f%%", Probability * 100)), hjust = -0.2, fontface = "bold", size = 3.8, color = "gray15") +
  scale_fill_gradient(low = "#b2c8f1", high = "#b30000") +
  scale_y_continuous(limits = c(0, 108), expand = c(0, 0)) +
  coord_flip() +
  labs(
    title = "The Compounding Vulnerability Spectrum",
    subtitle = "Predicted Probability of Zero-Dose Status by Intersecting Risk Profiles",
    x = "Sociodemographic & Obstetric Personas",
    y = "Predicted Probability of Being Zero-Dose (%)"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title = element_text(face = "bold", size = 13, color = "#1f4e78", margin = margin(b = 6)),
    plot.subtitle = element_text(face = "italic", size = 10, color = "gray30", margin = margin(b = 15)),
    axis.title.x = element_text(face = "bold", margin = margin(t = 12)),
    axis.title.y = element_text(face = "bold", margin = margin(r = 15)),
    axis.text.y = element_text(face = "bold", size = 9, color = "gray20", lineheight = 1.15),
    axis.text.x = element_text(face = "bold", color = "gray25"),
    panel.grid.major.x = element_line(color = "gray92", linetype = "dotted"),
    panel.grid.major.y = element_blank(),
    panel.border = element_rect(color = "gray80", fill = NA, linewidth = 0.5)
  )

ggsave(here("outputs", "figures", "Figure_2_Risk_Vulnerability_Spectrum.png"), plot = risk_plot, width = 11.5, height = 6.5, dpi = 300)
message("SUCCESS: Figure 2 saved.")

write.csv(
  persona_profiles,
  file = here("outputs", "powerbi", "powerbi_predicted_probabilities.csv"),
  row.names = FALSE,
  na = ""
)

message("SUCCESS: Power BI dataset exported.")


# ------------------------------------------------------------------------------
# 9. GIS EXPORT: STATE-LEVEL SURVEY AGGREGATION
# ------------------------------------------------------------------------------
message("Generating Survey-Weighted Zero-Dose spatial datasets for GIS engine...")

state_lookup <- c(
  "1" = "Sokoto", "2" = "Zamfara", "3" = "Katsina", "4" = "Jigawa",
  "10" = "Kano", "11" = "Kaduna", "12" = "Kebbi"
)

state_stats <- nw_survey_design %>%
  as_survey() %>%
  group_by(state_code) %>%
  summarize(
    weighted_mean = survey_mean(is_zero_dose, na.rm = TRUE),
    total_children_sampled = n(),
    actual_zero_dose_cases = sum(is_zero_dose == 1, na.rm = TRUE)
  ) %>%
  mutate(
    zero_dose_percentage = round(weighted_mean * 100, 2),
    zero_dose_se_percentage = round(weighted_mean_se * 100, 2),
    state_code_char = as.character(state_code),
    state_name = ifelse(state_code_char %in% names(state_lookup),
      state_lookup[state_code_char],
      state_code_char
    )
  ) %>%
  select(
    state_code,
    state_name,
    zero_dose_percentage,
    zero_dose_se_percentage,
    total_children_sampled,
    actual_zero_dose_cases
  )

overall_prevalence <- svymean(~is_zero_dose, nw_survey_design)

overall_prevalence_df <- data.frame(
  Indicator = "Northwest Zero-Dose Prevalence",
  Prevalence = coef(overall_prevalence) * 100,
  SE = SE(overall_prevalence) * 100
)

write.csv(
  overall_prevalence_df,
  file = here("outputs", "powerbi", "overall_prevalence.csv"),
  row.names = FALSE,
  na = ""
)

write.csv(
  state_stats,
  file = here("outputs", "gis", "gis_zero_dose_nw_rates.csv"),
  row.names = FALSE,
  na = ""
)

message("SUCCESS: GIS files exported.")

# 9.1 OVERALL SUMMARY TABLE (for Power BI Overview page)
overall_summary <- nw_survey_design %>%
  as_survey() %>%
  summarize(
    n_unweighted = unweighted(n()), # actual sample size interviewed
    N_weighted = survey_total(vartype = NULL), # weighted population estimate
    zero_dose_pct = survey_mean(is_zero_dose, vartype = "ci") * 100,
    vaccinated_pct = 100 - zero_dose_pct
  )

write.csv(
  overall_summary,
  file = here("outputs", "powerbi", "overall_summary.csv"),
  row.names = FALSE,
  na = ""
)
message("SUCCESS: Overall summary table exported.")

#-----------------------------------------------------------------------------------------
# 10. FIGURE 3: POLYGON OF ZERO-DOSE PREVALENCE BY STATE
#-----------------------------------------------------------------------------------------
message("Generating Figure 3: Spatial Prevalence Map...")
# Path matches the project schema: data/raw/boundaries/nga_admin1.{shp,shx,dbf,prj,cpg}
shp_path <- here("data", "raw", "boundaries", "nga_admin1.shp")
nigeria_shp <- st_read(shp_path, quiet = TRUE)

nigeria_shp <- nigeria_shp %>% mutate(join_key = tolower(adm1_name))
state_stats_join <- state_stats %>% mutate(join_key = tolower(state_name))

nw_shp_merged <- nigeria_shp %>%
  left_join(state_stats_join, by = "join_key")

plot_data <- nw_shp_merged %>% filter(!is.na(zero_dose_percentage))

spatial_map <- ggplot(data = plot_data) +
  geom_sf(aes(fill = zero_dose_percentage), color = "white", linewidth = 0.5) +
  geom_sf_text(aes(label = state_name),
    size = 3.5,
    fontface = "bold",
    color = "black",
    check_overlap = TRUE
  ) +
  scale_fill_distiller(palette = "YlOrRd", direction = 1, name = "Zero-Dose %") +
  guides(fill = guide_colorbar(
    frame.colour = "black",
    frame.linewidth = 1,
    ticks.colour = "black"
  )) +
  theme_void() +
  theme(
    panel.background = element_rect(fill = "white", color = NA),
    plot.background = element_rect(fill = "white", color = NA),
    panel.border = element_rect(color = "black", fill = NA, linetype = "dotted", linewidth = 1),
    plot.title = element_text(face = "bold", size = 18, color = "black", margin = margin(b = 10)),
    plot.subtitle = element_text(size = 14, color = "gray30", margin = margin(b = 15)),
    legend.position = "right",
    legend.title = element_text(face = "bold")
  ) +
  labs(
    title = "Prevalence of Zero-Dose Status among Children by State",
    subtitle = "North-West Nigeria"
  )

ggsave(here("outputs", "figures", "Figure_3_Spatial_Prevalence_Map.png"), plot = spatial_map, width = 11, height = 7, dpi = 300)
message("SUCCESS: Figure 3 saved.")

message("\n=== SUCCESS! ANALYSIS PIPELINE COMPLETED EXECUTION ===")


# ------------------------------------------------------------------------------
# 11. MODEL DIAGNOSTICS
# ------------------------------------------------------------------------------
message("Running model diagnostics...")

summary(nw_survey_design)
summary(zero_dose_model)

message("All outputs successfully exported to structured directories.")
message("Output structure ready for journal supplementary files, and technical reports.")

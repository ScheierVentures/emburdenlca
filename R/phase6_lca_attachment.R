# =============================================================================
# Phase 6 - LCA attachment
# -----------------------------------------------------------------------------
# Takes the Phase 5 household output (kwh_year, therms_year, 8760 profile cols)
# and attaches supply-chain + operational embodied-emissions columns using the
# dc_e2c3 LCA service bridge in R/global_lca_service.R.
#
# US 5-phase pipeline -> USEEIO (via lca_ghg_factors), NAICS 221100/221200.
# Global pipeline     -> EXIOBASE (via lca_exiobase_factors), region-mapped.
#
# The remote LCA service is flaky (SSH+pymrio, ~5 GB), so:
#   1. read a cached factor CSV first
#      (~/.cache/emburdendata/lca/{method}_household_factors_<REGION>.csv)
#   2. only fall back to the live bridge when the cache is missing
#   3. on ANY failure return phase5_output unchanged with lca_status="unavailable"
#
# See docs/ssa_footprint.md for the EXIOBASE region conventions.
# =============================================================================

# Assumed retail prices used to convert physical units to $ for USEEIO
# (kg CO2e / USD). Values are US 2022 residential averages (EIA); tune per
# study year via the `assumed_prices` argument.
.LCA_DEFAULT_PRICES <- c(
  usd_per_kwh   = 0.16,   # residential electricity, EIA 2022 avg
  usd_per_therm = 1.50    # residential natural gas, EIA 2022 avg
)

# USEEIO NAICS mapping for household energy carriers.
.LCA_USEEIO_NAICS <- c(
  electricity = "221100",  # Electric power gen / trans / dist
  natural_gas = "221200"   # Natural gas distribution
)

# EXIOBASE sector patterns for household energy carriers. These are substring
# regexes matched against the ~200 EXIOBASE products by the LCA service.
.LCA_EXIOBASE_SECTORS <- c(
  electricity = "Production of electricity nec",
  natural_gas = "Distribution of gaseous fuels through mains"
)

# EXIOBASE indicators used when indicator_set = "full". GHG is always fetched
# first because it is the most reliable indicator.
.LCA_EXIOBASE_INDICATORS <- c(
  co2e  = "GHG emissions",
  nox   = "NOx",
  so2   = "SO2",
  pm25  = "PM2.5",
  land  = "Land use"
)

# Read a cached household-fuel factor table if one exists. Columns expected:
#   fuel (character: "electricity" | "natural_gas")
#   indicator (character: "co2e" | "nox" | ...)
#   kg_per_unit (numeric)
#   unit (character: "kwh" | "therm")
.read_lca_cache <- function(cache_dir, method, region) {
  f <- file.path(cache_dir, sprintf("%s_household_factors_%s.csv",
                                     tolower(method), toupper(region)))
  if (!file.exists(f)) return(NULL)
  tryCatch(utils::read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
}

# Convert USEEIO GHG factors (kg CO2e per USD) to per-unit household factors
# using assumed retail prices. Returns a data.frame with the cache schema.
.useeio_household_factors <- function(host = "wright",
                                      prices = .LCA_DEFAULT_PRICES) {
  fac <- lca_ghg_factors(host = host)   # named numeric: NAICS -> kg CO2e / USD
  elec_naics <- .LCA_USEEIO_NAICS[["electricity"]]
  gas_naics  <- .LCA_USEEIO_NAICS[["natural_gas"]]
  if (!(elec_naics %in% names(fac))) stop("USEEIO factor missing for ", elec_naics)
  data.frame(
    fuel = c("electricity", "natural_gas"),
    indicator = c("co2e", "co2e"),
    kg_per_unit = c(
      unname(fac[[elec_naics]]) * prices[["usd_per_kwh"]],
      if (gas_naics %in% names(fac))
        unname(fac[[gas_naics]]) * prices[["usd_per_therm"]] else NA_real_
    ),
    unit = c("kwh", "therm"),
    stringsAsFactors = FALSE
  )
}

# EXIOBASE bridge: fetch (region|sector) multipliers for one or more indicators
# and reshape into the cache schema. Multipliers are per M.EUR; assumed prices
# are converted USD -> EUR via `eur_per_usd`.
.exiobase_household_factors <- function(region,
                                        host = "wright",
                                        indicators = c("co2e"),
                                        prices = .LCA_DEFAULT_PRICES,
                                        eur_per_usd = 0.72) {
  sectors <- .LCA_EXIOBASE_SECTORS
  pairs <- lapply(unname(sectors), function(s) c(region, s))
  rows <- list()
  for (ind in indicators) {
    ind_name <- .LCA_EXIOBASE_INDICATORS[[ind]]
    if (is.null(ind_name)) next
    fac_raw <- tryCatch(
      lca_exiobase_factors(pairs, indicator = ind_name, host = host),
      error = function(e) NULL)
    if (is.null(fac_raw)) next
    key_e <- paste0(region, "|", sectors[["electricity"]])
    key_g <- paste0(region, "|", sectors[["natural_gas"]])
    # Multiplier per M.EUR -> per unit: unit_usd * eur_per_usd / 1e6 * mult
    per_kwh   <- if (key_e %in% names(fac_raw))
      unname(fac_raw[[key_e]]) * prices[["usd_per_kwh"]] * eur_per_usd / 1e6
      else NA_real_
    per_therm <- if (key_g %in% names(fac_raw))
      unname(fac_raw[[key_g]]) * prices[["usd_per_therm"]] * eur_per_usd / 1e6
      else NA_real_
    rows[[length(rows) + 1L]] <- data.frame(
      fuel = c("electricity", "natural_gas"),
      indicator = ind, kg_per_unit = c(per_kwh, per_therm),
      unit = c("kwh", "therm"), stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

# Apply a factor table (cache schema) to phase5_output. Attaches one column per
# indicator in the table: co2e_kg_year, nox_kg_year, ...
.apply_factors <- function(phase5_output, factors, indicators) {
  kwh   <- if ("kwh_year"   %in% names(phase5_output)) phase5_output$kwh_year   else NA_real_
  therm <- if ("therms_year" %in% names(phase5_output)) phase5_output$therms_year else NA_real_
  out <- phase5_output
  for (ind in indicators) {
    sub <- factors[factors$indicator == ind, , drop = FALSE]
    fe  <- sub$kg_per_unit[sub$fuel == "electricity"]
    fg  <- sub$kg_per_unit[sub$fuel == "natural_gas"]
    fe  <- if (length(fe)) fe[[1L]] else NA_real_
    fg  <- if (length(fg)) fg[[1L]] else NA_real_
    val <- rep(0, nrow(out))
    if (!is.na(fe)) val <- val + ifelse(is.na(kwh),   0, kwh)   * fe
    if (!is.na(fg)) val <- val + ifelse(is.na(therm), 0, therm) * fg
    if (is.na(fe) && is.na(fg)) val <- rep(NA_real_, nrow(out))
    out[[paste0(ind, "_kg_year")]] <- val
  }
  # land units are m2, not kg; rename if attached
  if ("land_kg_year" %in% names(out)) {
    out$land_m2_year <- out$land_kg_year
    out$land_kg_year <- NULL
  }
  out
}

#' Attach embodied-emissions columns to a Phase 5 household output
#'
#' Multiplies each household's annual electricity (kWh) and natural-gas (therms)
#' consumption by supply-chain + operational emission factors from the dc_e2c3
#' LCA service (USEEIO for USA, EXIOBASE for the rest of the world). Attempts
#' cache-first, falls back to the live bridge, and gracefully degrades to a
#' `lca_status = "unavailable"` column if neither is reachable.
#'
#' @param phase5_output Tibble/data.frame from [generate_load_profiles()] with
#'   at least `hh_synthetic_id` and one of `kwh_year` / `therms_year`.
#' @param iso3 ISO3 country code (used to pick the LCA region).
#' @param method One of "auto", "exiobase", "useeio". "auto" picks USEEIO for
#'   USA and EXIOBASE otherwise.
#' @param indicator_set "ghg" attaches `co2e_kg_year` only; "full" additionally
#'   attempts `nox_kg_year`, `so2_kg_year`, `pm25_kg_year`, `land_m2_year`
#'   (EXIOBASE only - USEEIO returns GHG-only and non-GHG columns will be NA).
#' @param cache_dir Directory holding cached household-fuel factor CSVs
#'   (default `~/.cache/emburdendata/lca`). See internal `.read_lca_cache()`
#'   for the schema.
#' @param host SSH host running the dc_e2c3 LCA service (default "wright").
#' @param assumed_prices Named numeric vector with `usd_per_kwh`,
#'   `usd_per_therm` used to convert per-USD EEIO factors to per-unit.
#' @param eur_per_usd USD->EUR conversion for the ~2011 EXIOBASE basis.
#' @param verbose Print progress messages.
#' @return `phase5_output` with the emissions columns and provenance columns
#'   `lca_method`, `lca_region`, `lca_status` attached.
#' @export
attach_lca_footprint <- function(phase5_output,
                                 iso3,
                                 method = c("auto", "exiobase", "useeio"),
                                 indicator_set = c("ghg", "full"),
                                 cache_dir = NULL,
                                 host = "wright",
                                 assumed_prices = .LCA_DEFAULT_PRICES,
                                 eur_per_usd = 0.72,
                                 verbose = TRUE) {
  stopifnot(is.data.frame(phase5_output))
  if (missing(iso3) || !is.character(iso3) || length(iso3) != 1L || nchar(iso3) != 3L)
    stop("iso3 must be a single 3-letter ISO country code")
  method <- match.arg(method)
  indicator_set <- match.arg(indicator_set)
  if (!any(c("kwh_year", "therms_year") %in% names(phase5_output)))
    stop("phase5_output must contain kwh_year and/or therms_year")

  iso3 <- toupper(iso3)
  if (method == "auto") method <- if (iso3 == "USA") "useeio" else "exiobase"
  region <- if (method == "useeio") "USA" else exiobase_region_for_iso3(iso3)
  if (is.null(cache_dir)) cache_dir <- "~/.cache/emburdendata/lca"
  cache_dir <- path.expand(cache_dir)

  indicators <- if (indicator_set == "ghg") "co2e"
                else c("co2e", "nox", "so2", "pm25", "land")

  if (verbose)
    message(sprintf("[phase6] LCA method=%s region=%s indicators=%s",
                    method, region, paste(indicators, collapse = ",")))

  # 1. cache lookup
  fac <- .read_lca_cache(cache_dir, method, region)
  # 2. live bridge fallback
  if (is.null(fac)) {
    fac <- tryCatch({
      if (method == "useeio") {
        .useeio_household_factors(host = host, prices = assumed_prices)
      } else {
        .exiobase_household_factors(region = region, host = host,
                                    indicators = indicators,
                                    prices = assumed_prices,
                                    eur_per_usd = eur_per_usd)
      }
    }, error = function(e) { if (verbose) message("  bridge error: ", conditionMessage(e)); NULL })
  }
  if (is.null(fac) || !nrow(fac)) {
    warning("dc_e2c3 LCA service unavailable and no cache found; ",
            "attaching lca_status='unavailable' and returning input unchanged.")
    phase5_output$lca_method <- method
    phase5_output$lca_region <- region
    phase5_output$lca_status <- "unavailable"
    return(phase5_output)
  }

  # 3. apply factors
  present <- intersect(indicators, unique(fac$indicator))
  out <- .apply_factors(phase5_output, fac, present)
  # NA-pad any requested indicator we could not source
  for (ind in setdiff(indicators, present)) {
    col <- if (ind == "land") "land_m2_year" else paste0(ind, "_kg_year")
    out[[col]] <- NA_real_
  }
  out$lca_method <- method
  out$lca_region <- region
  out$lca_status <- if (length(present) == length(indicators)) "ok" else "partial"
  out
}

#' Sanity-check a Phase 6 LCA attachment against national totals
#'
#' Compares per-household mean CO2e and the implied national total against a
#' small built-in reference table (EDGAR / WRI CAIT residential energy totals,
#' MtCO2e per year, ca. 2020). Returns `NULL` if the country is not in the
#' reference table so the caller can skip gracefully.
#'
#' @param phase6_output Output of [attach_lca_footprint()] with `co2e_kg_year`.
#' @param iso3 ISO3 code used in the attachment.
#' @param verbose Print a one-line summary.
#' @return A one-row data.frame (`iso3, n_hh, mean_kg_co2e_hh,
#'   implied_national_mtco2e, reference_mtco2e, ratio`) or NULL.
#' @export
phase6_lca_diagnostics <- function(phase6_output, iso3, verbose = TRUE) {
  stopifnot(is.data.frame(phase6_output))
  if (!"co2e_kg_year" %in% names(phase6_output)) return(NULL)
  if (!"lca_status" %in% names(phase6_output) ||
      all(phase6_output$lca_status == "unavailable")) return(NULL)

  # EDGAR v7 residential-energy CO2e totals, MtCO2e/yr, ca. 2020. Extend as needed.
  ref <- data.frame(
    iso3 = c("USA", "GBR", "ZAF", "IND", "NGA", "DEU", "FRA", "BRA"),
    mtco2e = c(1050, 87, 15, 130, 12, 118, 72, 25),
    n_households_millions = c(128.5, 28.1, 17.3, 298.0, 40.0, 41.5, 30.2, 72.0),
    stringsAsFactors = FALSE)
  hit <- ref[ref$iso3 == toupper(iso3), , drop = FALSE]
  if (!nrow(hit)) return(NULL)

  wt <- if ("hh_weight" %in% names(phase6_output)) phase6_output$hh_weight
        else rep(1, nrow(phase6_output))
  mean_kg <- stats::weighted.mean(phase6_output$co2e_kg_year, wt, na.rm = TRUE)
  implied_mt <- mean_kg * hit$n_households_millions[1L] * 1e6 / 1e9
  out <- data.frame(
    iso3 = toupper(iso3),
    n_hh = nrow(phase6_output),
    mean_kg_co2e_hh = mean_kg,
    implied_national_mtco2e = implied_mt,
    reference_mtco2e = hit$mtco2e[1L],
    ratio = implied_mt / hit$mtco2e[1L],
    stringsAsFactors = FALSE)
  if (verbose)
    message(sprintf("[phase6-diag] %s: mean=%.0f kg/hh, implied=%.1f Mt vs ref=%.1f Mt (ratio=%.2f)",
                    out$iso3, out$mean_kg_co2e_hh, out$implied_national_mtco2e,
                    out$reference_mtco2e, out$ratio))
  out
}

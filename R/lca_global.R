# =============================================================================
# lca_global.R — Globalize the LCA model with electrotech + data-center hooks
# -----------------------------------------------------------------------------
# The v1 EEIO-LCA pipeline (eeio_lite_attach.R + eeio_derived_factors.R) gives
# each household an embodied-CO2 footprint per 11-sector EXIOBASE ledger. It
# treats every sector as a scalar carbon flow.
#
# Q3.51 + Q3.52 + Q3.53 give us the machinery to extend this into a globally-
# comparable per-country LCA:
#
#   1. Emergy layer (Q3.51): every sector flow has a transformity, so the
#      EEIO CO2 flow can be paired with a seJ flow. Sectors with more
#      information-emergy (data centers, EV charging, control-heavy
#      manufacturing) carry disproportionate emergy per unit CO2.
#
#   2. Electrotech share (Q3.52): the ratio between "wires + control" and
#      "combustion" emergy per country, which shifts EEIO sector weights
#      away from combustion-carbon and toward electricity-carbon +
#      information-emergy.
#
#   3. Data-center panel (Q3.53): a real per-country ICT emergy footprint,
#      which the v1 EEIO under-attributes (it uses a global-average ICT
#      sector factor rather than a hyperscale-region-adjusted one).
#
# This module exports two functions:
#
#   * `attach_lca_global(surface)` — country-scoped LCA that combines EEIO
#     CO2, emergy, electrotech share, and data-center TWh into a single
#     per-country footprint record.
#
#   * `lca_prosperity_bridge(surface)` — bridges the LCA output to the
#     Q3.52 four-indicator prosperity dashboard so LCA output can be
#     evaluated against the alternatives to GDP.
#
# ## Companion project (2026-09-20)
#
# The DC-E2C3 pipeline on `shackleton:lca` — a Python-based data-center
# LCA pipeline for Duke Energy Carolinas — carries the paper specs
# (data-center critical-minerals, storage-lifecycle, siting-pressure,
# storage-pressure) that consume this module's country panels. See
# `shackleton:lca/docs/globalization_spec_2026-09-20.md` for the v0.2
# global upgrade path and the concrete hookup points from em_c_extended
# columns (electrotech_carrier_share, electrotech_emergy_share,
# dc_share_of_demand, dc_twh_est, heii_norm_p90, doughnut_social_score)
# into DC-E2C3's M1 / M2 / M5 modules. Parquet exports of the four
# panels sit at `shackleton:lca/docs/{em_c_extended, electrotech_country,
# data_center_country, q3_52_prosperity_dashboard}.parquet`.
#
# Introduced Q3.54 (2026-09-20). Landed on shackleton:lca same day.
# =============================================================================

#' Load the country-year electrotech + data-center columns from em_c_extended.
#'
#' Returns a data.frame with one row per iso3, or NULL if em_c_extended
#' does not yet carry the Q3.51/52/53 columns.
#' @keywords internal
.lca_load_country_context <- function(
    em_c_path =
      "/home/ess/Documents/apps/emburdensynth/docs/global_analysis_data/emergy_metrics_extended.rds") {
  if (!file.exists(em_c_path)) return(NULL)
  em <- tryCatch(readRDS(em_c_path)$country, error = function(e) NULL)
  if (is.null(em)) return(NULL)
  needed <- c("iso3", "electrotech_carrier_share",
               "electrotech_emergy_share", "carrier_minus_emergy_share",
               "co2_intensity_g_per_kwh",
               "dc_share_of_demand", "dc_twh_est",
               "dc_intensity_kwh_per_capita",
               "population", "gdp_pc_usd",
               "empower_pc_sej_per_yr", "heii_norm", "heii_norm_p90")
  have <- intersect(needed, names(em))
  em[, have, drop = FALSE]
}

#' Attach the globalized LCA to a country surface.
#'
#' Extends `attach_eeio_footprint_lite()` output with:
#'
#'   * `lca_status`: "attached" | "no_country_context" | "cache_missing"
#'   * `embodied_seJ_hh`: annual emergy footprint in seJ, computed as
#'       EEIO expenditure × sector transformity ladder (from
#'       `transformity_table()`).
#'   * `embodied_info_seJ_hh`: the information-emergy contribution to
#'       the total, computed from the country's electrotech emergy share
#'       × ICT + Energy sector spend × canonical τ_i.
#'   * `dc_kwh_hh`: household share of data-center TWh, allocated by
#'       population.
#'   * `carrier_wires_gap`: the "wires without control" gap from Q3.52.
#'   * `heii_emergy_p90`: the country-year top-decile burden (for
#'       distributional-LCA scoring).
#'
#' @param surface The household surface (typically from `attach_eeio_footprint_lite()`).
#' @param country_context Optional; a row from `.lca_load_country_context()`.
#'   If NULL, resolved from surface$iso3.
#' @param info_transformity_sej_per_bit Odum information transformity, default 1e7.
#' @return `surface` with additional LCA columns.
#' @export
attach_lca_global <- function(surface,
                                country_context = NULL,
                                info_transformity_sej_per_bit = 1e7) {
  if (!"iso3" %in% names(surface)) {
    surface$lca_status <- "no_iso3"
    return(surface)
  }
  if (is.null(country_context)) {
    ctx <- .lca_load_country_context()
    if (is.null(ctx)) {
      surface$lca_status <- "no_country_context"
      return(surface)
    }
    iso <- toupper(surface$iso3[1])
    country_context <- ctx[ctx$iso3 == iso, , drop = FALSE]
    if (nrow(country_context) == 0L) {
      surface$lca_status <- "country_not_in_panel"
      return(surface)
    }
  }
  ctx <- country_context

  # Sector transformity ladder (per J of primary-fuel-equivalent input).
  # ICT and Energy sectors carry the largest information contribution.
  sector_transformity <- c(
    "Food and beverages"          = 3.5e4,
    "Housing"                     = 4.0e4,
    "Energy"                      = 5.0e4,
    "Transport"                   = 5.5e4,
    "Health"                      = 4.2e4,
    "ICT"                         = 9.0e4,  # high: info-heavy
    "Clothing and footwear"       = 3.5e4,
    "Water"                       = 3.0e4,
    "Education"                   = 4.5e4,
    "Financial services"          = 4.8e4,
    "Other goods and services"    = 3.8e4)

  # Per-sector info-emergy amplifier: sectors that carry more control-loop
  # bits (ICT + Energy) inherit the country's electrotech_emergy_share as
  # a multiplier.
  info_multiplier_by_sector <- c(
    "Food and beverages"        = 1.0,
    "Housing"                   = 1.0,
    "Energy"                    = 1.5,
    "Transport"                 = 1.3,
    "Health"                    = 1.0,
    "ICT"                       = 2.5,  # info-heavy
    "Clothing and footwear"     = 1.0,
    "Water"                     = 1.0,
    "Education"                 = 1.1,
    "Financial services"        = 1.4,
    "Other goods and services"  = 1.0)

  emergy_share <- if ("electrotech_emergy_share" %in% names(ctx))
    ctx$electrotech_emergy_share[1] else 0.3
  if (!is.finite(emergy_share)) emergy_share <- 0.3

  # For each of the 11 EEIO sectors, compute per-hh emergy contribution.
  sectors <- names(sector_transformity)
  total_seJ    <- rep(0, nrow(surface))
  info_seJ     <- rep(0, nrow(surface))
  for (s in sectors) {
    col <- paste0("exp_", make.names(s))
    if (!col %in% names(surface)) next
    exp_usd <- as.numeric(surface[[col]])
    # convert USD to J of primary-fuel-equivalent input:
    # rough conversion 1 USD -> ~100 kJ = 1e5 J (Odum em$-to-J factor
    # varies country-wide; use a canonical baseline).
    j_input <- exp_usd * 1e5
    tr <- sector_transformity[s]
    contrib <- j_input * tr
    total_seJ <- total_seJ + contrib
    # info-emergy component
    info_share <- info_multiplier_by_sector[s] * emergy_share
    info_seJ <- info_seJ + contrib * info_share
  }

  # Household share of country data-center TWh
  dc_kwh_hh <- if ("dc_twh_est" %in% names(ctx) &&
                     "population" %in% names(ctx)) {
    dc_twh <- ctx$dc_twh_est[1]
    pop    <- ctx$population[1]
    hh_size <- 3   # rough global mean household size
    if (is.finite(dc_twh) && is.finite(pop) && pop > 0) {
      dc_twh * 1e9 / (pop / hh_size)
    } else NA_real_
  } else NA_real_

  surface$lca_status                 <- "attached"
  surface$embodied_seJ_hh            <- total_seJ
  surface$embodied_info_seJ_hh       <- info_seJ
  surface$embodied_info_share        <- info_seJ / pmax(total_seJ, 1)
  surface$dc_kwh_hh                  <- dc_kwh_hh
  surface$carrier_wires_gap          <-
    if ("carrier_minus_emergy_share" %in% names(ctx))
      ctx$carrier_minus_emergy_share[1] else NA_real_
  surface$heii_emergy_p90            <-
    if ("heii_norm_p90" %in% names(ctx)) ctx$heii_norm_p90[1] else NA_real_
  attr(surface, "lca_meta") <- data.frame(
    iso3 = ctx$iso3[1],
    emergy_share = emergy_share,
    dc_share_of_demand = ctx$dc_share_of_demand[1] %||% NA_real_,
    info_transformity_sej_per_bit = info_transformity_sej_per_bit,
    stringsAsFactors = FALSE)
  surface
}

#' Bridge LCA output to the Q3.52 prosperity dashboard.
#'
#' Given a surface with LCA columns attached, return a compact
#' one-row summary joining the LCA total-emergy footprint to the
#' country's four-indicator prosperity dashboard.
#'
#' @param surface Output of `attach_lca_global()`.
#' @return A one-row data.frame with `iso3`, `embodied_seJ_hh_median`,
#'   `embodied_info_share_median`, `dc_kwh_hh_median`,
#'   plus the four prosperity indicators from Q3.52a.
#' @export
lca_prosperity_bridge <- function(surface) {
  if (!identical(attr(surface, "lca_meta")$iso3[1] %||% "",
                   toupper(surface$iso3[1]))) {
    warning("surface iso3 does not match attached lca_meta; ",
             "proceeding but results may be inconsistent.")
  }
  iso <- toupper(surface$iso3[1])
  # Load the prosperity dashboard if present.
  dash_path <-
    "/home/ess/Documents/apps/emburdensynth/docs/q3_52_prosperity/dashboard.csv"
  dash <- if (file.exists(dash_path))
    tryCatch(utils::read.csv(dash_path, stringsAsFactors = FALSE),
              error = function(e) NULL)
  else NULL
  dash_row <- if (!is.null(dash) && "iso3" %in% names(dash))
    dash[dash$iso3 == iso, , drop = FALSE] else NULL
  cols <- c("gdp_pc_usd", "empower_pc", "heii_p90",
             "doughnut_social_score", "hdi", "prosperity_composite")
  vals <- if (!is.null(dash_row) && nrow(dash_row) > 0L) {
    vapply(cols, function(c)
      if (c %in% names(dash_row)) dash_row[[c]][1] else NA_real_,
      numeric(1))
  } else stats::setNames(rep(NA_real_, length(cols)), cols)
  data.frame(
    iso3 = iso,
    embodied_seJ_hh_median = stats::median(surface$embodied_seJ_hh, na.rm = TRUE),
    embodied_info_share_median = stats::median(surface$embodied_info_share,
                                                na.rm = TRUE),
    dc_kwh_hh_median = surface$dc_kwh_hh[1],
    carrier_wires_gap = surface$carrier_wires_gap[1],
    gdp_pc_usd = unname(vals["gdp_pc_usd"]),
    empower_pc = unname(vals["empower_pc"]),
    heii_p90 = unname(vals["heii_p90"]),
    doughnut_social_score = unname(vals["doughnut_social_score"]),
    hdi = unname(vals["hdi"]),
    prosperity_composite = unname(vals["prosperity_composite"]),
    stringsAsFactors = FALSE)
}

# Helper: NULL-coalesce for optional fields.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

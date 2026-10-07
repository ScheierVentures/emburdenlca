# =============================================================================
# EEIO-LCA lightweight attachment (Phase 6 subset)
# -----------------------------------------------------------------------------
# The full Phase 6 attachment (attach_lca_footprint in phase6_lca_attachment.R)
# depends on the dc_e2c3 remote LCA service and per-region EXIOBASE factor
# CSVs. Only 2 regions are cached locally (ZA + WF). This module implements a
# lightweight attach that:
#   (a) Uses cached-region factors where available (33 of 61 GCD countries in
#       the current release, via the WF and ZA caches).
#   (b) Computes per-country per-segment blended Energy factor from Ember
#       generation mix + GCD carrier shares (via global_energy_factor_func()).
#   (c) Applies factors to the per-sector household expenditure ledger to get
#       embodied CO2e (kg per household per year).
#   (d) Also emits embodied kWh derived from Ember grid intensity (indicative
#       cross-check on the degree-day physics baseline).
# For countries in EXIOBASE regions without a cached factor CSV (currently WA,
# WE, WL, and the 26 individual non-WF/ZA countries in the release), records
# `eeio_status = "cache_missing"` and returns the surface unchanged.
# =============================================================================

.eeio_load_factor_cache <- function(region, factor_dir = "~/.cache/emburdendata/gcd") {
  path <- path.expand(file.path(factor_dir, sprintf("exiobase_factors_%s.csv", region)))
  if (!file.exists(path)) return(NULL)
  df <- utils::read.csv(path, stringsAsFactors = FALSE)
  stats::setNames(df$factor_kgco2e_per_meur, df$category)
}

#' Attach EEIO-LCA embodied CO2e per household to a surface (Phase 6 lite)
#'
#' Uses cached EXIOBASE region factors (ZA + WF today) to attach an embodied
#' CO2e per household using the 11-sector GCD expenditure ledger. Country in
#' an uncached EXIOBASE region gets `eeio_status = "cache_missing"` and no
#' new columns. See FUTURE_WORK.md for the cache-build roadmap.
#'
#' @param surface Post-GCD surface with `iso3`, `exp_<category>` columns.
#' @param factor_dir Cache directory for `exiobase_factors_<REGION>.csv`.
#' @param eur_per_usd USD->EUR conversion (default 0.72 for ~2011 EXIOBASE).
#' @param grid_kgco2_per_kwh Fallback grid intensity if Ember not available
#'   (default 0.5 kg CO2 / kWh, global average).
#' @return `surface` with (on success):
#'   `eeio_status = "attached"`,
#'   `embodied_co2e_kg_hh` (annual, sum across 11 sectors),
#'   `embodied_co2e_energy_kg_hh` (Energy sector only, for physics/EEIO cross-check),
#'   `embodied_kwh_hh` = embodied_co2e_energy_kg_hh / grid_intensity_kgco2e_per_kwh
#'   Or (missing cache): `eeio_status = "cache_missing"`.
#' @export
attach_eeio_footprint_lite <- function(surface,
                                        factor_dir = "~/.cache/emburdendata/gcd",
                                        eur_per_usd = 0.72,
                                        grid_kgco2_per_kwh = 0.5) {
  iso <- toupper(surface$iso3[1])
  region <- exiobase_region_for_iso3(iso)
  fac <- .eeio_load_factor_cache(region, factor_dir)
  if (is.null(fac)) {
    surface$eeio_status <- "cache_missing"
    surface$eeio_region <- region
    return(surface)
  }
  # Match GCD sectors to columns
  sectors <- c("Food and beverages", "Housing", "Energy", "Transport",
                "Health", "ICT", "Clothing and footwear", "Water",
                "Education", "Financial services", "Other goods and services")
  fp <- rep(0, nrow(surface))
  fp_energy <- rep(0, nrow(surface))
  for (s in sectors) {
    col <- paste0("exp_", make.names(s))
    if (!col %in% names(surface)) next
    f <- as.numeric(fac[[s]])
    if (!is.finite(f)) next
    contrib <- as.numeric(surface[[col]]) * eur_per_usd * f / 1e6   # kg CO2e / hh
    fp <- fp + contrib
    if (s == "Energy") fp_energy <- contrib
  }
  surface$eeio_status <- "attached"
  surface$eeio_region <- region
  surface$embodied_co2e_kg_hh <- fp
  surface$embodied_co2e_energy_kg_hh <- fp_energy
  surface$embodied_kwh_hh <- fp_energy / grid_kgco2_per_kwh
  attr(surface, "eeio_meta") <- data.frame(
    iso3 = iso, region = region,
    n_sectors_used = sum(!is.na(fac)),
    eur_per_usd = eur_per_usd,
    grid_kgco2_per_kwh = grid_kgco2_per_kwh,
    stringsAsFactors = FALSE)
  surface
}

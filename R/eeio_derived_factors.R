# =============================================================================
# EEIO-LCA factor derivation for countries beyond cached EXIOBASE regions
# -----------------------------------------------------------------------------
# The v1 attach_eeio_footprint_lite only fires for countries in cached
# EXIOBASE regions (ZA + WF today). This module extends the pipeline by
# DERIVING per-country factors from the cached WF baseline scaled by:
#
#   * Ember 2020 grid CO2 intensity  (Energy sector, primary driver)
#   * (optional) sector-specific PPP adjustments (not yet)
#
# This gives every country an EEIO estimate — with the caveat that non-
# Energy sectors inherit the WF regional multiplier and only the Energy
# sector scales properly with the country's grid mix. Documented in the
# report so readers know which sector is well-calibrated and which is
# approximate.
# =============================================================================

.load_ember_grid_intensity <- function(cache_path = "~/.cache/emburdendata/ember/ember.csv") {
  p <- path.expand(cache_path)
  if (!file.exists(p)) return(NULL)
  d <- utils::read.csv(p, stringsAsFactors = FALSE)
  # Ember read.csv converts spaces to dots — "ISO 3 code" → "ISO.3.code"
  iso_col <- intersect(c("ISO.3.code","ISO 3 code","iso3","country_code"),
                        names(d))[1]
  if (is.na(iso_col)) return(NULL)
  hits <- d[d$Variable == "CO2 intensity" & d$Year == 2020, , drop = FALSE]
  if (nrow(hits) == 0L) return(NULL)
  out <- data.frame(
    iso3 = hits[[iso_col]],
    grid_kgco2_per_kwh = hits$Value / 1000,   # Ember gCO2/kWh -> kgCO2/kWh
    stringsAsFactors = FALSE)
  out[!is.na(out$iso3) & is.finite(out$grid_kgco2_per_kwh), , drop = FALSE]
}

#' Attach EEIO-LCA embodied CO2e for ALL countries via derived factors
#'
#' Uses cached WF/ZA EXIOBASE factors as the baseline. For countries in
#' uncached regions, computes the Energy-sector factor as:
#'   Energy_factor_iso = WF_Energy_factor × (grid_intensity_iso / grid_intensity_WF)
#' All other sectors inherit the WF regional multiplier.
#'
#' @param surface Per-country cell surface with `iso3` + `exp_<sector>`.
#' @return `surface` with embodied_co2e_kg_hh (attached where possible)
#'   plus `eeio_status` label ("attached_cached" | "attached_derived" |
#'   "no_grid_data").
#' @export
attach_eeio_derived <- function(surface,
                                factor_dir = "~/.cache/emburdendata/gcd",
                                eur_per_usd = 0.72,
                                default_grid_kgco2_per_kwh = 0.5) {
  iso <- toupper(surface$iso3[1])
  region <- exiobase_region_for_iso3(iso)
  fac_cached <- .eeio_load_factor_cache(region, factor_dir)
  if (!is.null(fac_cached)) {
    s <- attach_eeio_footprint_lite(surface, factor_dir, eur_per_usd,
                                     default_grid_kgco2_per_kwh)
    if ("eeio_status" %in% names(s)) s$eeio_status <- "attached_cached"
    return(s)
  }
  # Uncached region — derive from WF baseline + Ember grid intensity
  fac_wf <- .eeio_load_factor_cache("WF", factor_dir)
  if (is.null(fac_wf)) {
    surface$eeio_status <- "cache_missing"
    return(surface)
  }
  ember <- .load_ember_grid_intensity()
  if (is.null(ember) || !iso %in% ember$iso3) {
    surface$eeio_status <- "no_grid_data"
    return(surface)
  }
  # Grid-intensity ratio
  wf_grid_intensity <- if ("ZAF" %in% ember$iso3)
    ember$grid_kgco2_per_kwh[ember$iso3 == "ZAF"][1] else 0.83
  iso_grid <- ember$grid_kgco2_per_kwh[ember$iso3 == iso][1]
  scale_energy <- iso_grid / wf_grid_intensity
  # Compose derived factor vector
  derived <- fac_wf
  derived["Energy"] <- derived["Energy"] * scale_energy
  # Apply to surface
  sectors <- names(derived)
  fp <- rep(0, nrow(surface))
  fp_energy <- rep(0, nrow(surface))
  for (s in sectors) {
    col <- paste0("exp_", make.names(s))
    if (!col %in% names(surface)) next
    f <- as.numeric(derived[[s]])
    if (!is.finite(f)) next
    contrib <- as.numeric(surface[[col]]) * eur_per_usd * f / 1e6
    fp <- fp + contrib
    if (s == "Energy") fp_energy <- contrib
  }
  surface$eeio_status <- "attached_derived"
  surface$eeio_region <- region
  surface$embodied_co2e_kg_hh <- fp
  surface$embodied_co2e_energy_kg_hh <- fp_energy
  surface$embodied_kwh_hh <- fp_energy / iso_grid
  attr(surface, "eeio_meta") <- data.frame(
    iso3 = iso, region = region,
    method = "derived_from_WF",
    energy_scale = scale_energy,
    iso_grid_kgco2_per_kwh = iso_grid,
    stringsAsFactors = FALSE)
  surface
}

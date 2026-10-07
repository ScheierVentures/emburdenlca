# Tests for Phase 6: LCA attachment
#
# Argument validation + smoke test for the "LCA service unavailable" fallback
# path. Uses a non-existent cache_dir and a bogus SSH host to force the graceful
# degradation branch - no remote call is made.

test_that("attach_lca_footprint validates its arguments", {
  df <- tibble::tibble(hh_synthetic_id = 1:2, kwh_year = c(8000, 12000),
                       therms_year = c(400, 600))
  # missing iso3
  expect_error(attach_lca_footprint(df))
  # bad iso3 (not length-3)
  expect_error(attach_lca_footprint(df, iso3 = "US"))
  # method must match
  expect_error(attach_lca_footprint(df, iso3 = "USA", method = "bogus"))
  # indicator_set must match
  expect_error(
    attach_lca_footprint(df, iso3 = "USA", indicator_set = "everything"))
  # missing energy columns
  expect_error(
    attach_lca_footprint(tibble::tibble(hh_synthetic_id = 1:2), iso3 = "USA"))
})

test_that("attach_lca_footprint attaches lca_status='unavailable' when bridge/cache both miss", {
  df <- tibble::tibble(hh_synthetic_id = 1:2, kwh_year = c(8000, 12000),
                       therms_year = c(400, 600))
  tmp <- tempfile("lca_cache_"); dir.create(tmp)
  suppressWarnings({
    out <- attach_lca_footprint(
      df, iso3 = "USA", method = "useeio",
      cache_dir = tmp,
      host = "nonexistent.invalid.host.example",
      verbose = FALSE)
  })
  expect_s3_class(out, "data.frame")
  expect_true(all(c("lca_method", "lca_region", "lca_status") %in% names(out)))
  expect_equal(unique(out$lca_status), "unavailable")
  expect_equal(unique(out$lca_method), "useeio")
  expect_equal(unique(out$lca_region), "USA")
  # returned unchanged: no emissions column
  expect_false("co2e_kg_year" %in% names(out))
})

test_that("attach_lca_footprint 'auto' picks USEEIO for USA, EXIOBASE otherwise", {
  df <- tibble::tibble(hh_synthetic_id = 1L, kwh_year = 8000, therms_year = 400)
  tmp <- tempfile("lca_cache_"); dir.create(tmp)
  suppressWarnings({
    us <- attach_lca_footprint(df, iso3 = "USA", method = "auto",
                               cache_dir = tmp,
                               host = "nonexistent.invalid.host.example",
                               verbose = FALSE)
    ke <- attach_lca_footprint(df, iso3 = "KEN", method = "auto",
                               cache_dir = tmp,
                               host = "nonexistent.invalid.host.example",
                               verbose = FALSE)
  })
  expect_equal(unique(us$lca_method), "useeio")
  expect_equal(unique(us$lca_region), "USA")
  expect_equal(unique(ke$lca_method), "exiobase")
  expect_equal(unique(ke$lca_region), "WF")   # EXIOBASE Rest-of-Africa
})

test_that("attach_lca_footprint applies factors from a cache CSV (no bridge call)", {
  df <- tibble::tibble(hh_synthetic_id = 1:2, kwh_year = c(10000, 5000),
                       therms_year = c(500, 250))
  tmp <- tempfile("lca_cache_"); dir.create(tmp)
  fac <- data.frame(
    fuel = c("electricity", "natural_gas"),
    indicator = c("co2e", "co2e"),
    kg_per_unit = c(0.4, 5.3),   # kg CO2e/kWh, kg CO2e/therm
    unit = c("kwh", "therm"),
    stringsAsFactors = FALSE)
  utils::write.csv(fac, file.path(tmp, "useeio_household_factors_USA.csv"),
                   row.names = FALSE)
  out <- attach_lca_footprint(
    df, iso3 = "USA", method = "useeio",
    cache_dir = tmp, verbose = FALSE)
  expect_true("co2e_kg_year" %in% names(out))
  expect_equal(unique(out$lca_status), "ok")
  # hh1: 10000*0.4 + 500*5.3 = 4000 + 2650 = 6650
  expect_equal(out$co2e_kg_year[1L], 6650)
  # hh2: 5000*0.4 + 250*5.3 = 2000 + 1325 = 3325
  expect_equal(out$co2e_kg_year[2L], 3325)
})

test_that("phase6_lca_diagnostics returns NULL for unknown iso3 and skips 'unavailable'", {
  df <- tibble::tibble(hh_synthetic_id = 1:2, co2e_kg_year = c(5000, 6000),
                       lca_status = c("ok", "ok"))
  # unknown iso3 - not in reference table
  expect_null(phase6_lca_diagnostics(df, iso3 = "XKX", verbose = FALSE))
  # all rows unavailable
  df2 <- df; df2$lca_status <- "unavailable"
  expect_null(phase6_lca_diagnostics(df2, iso3 = "USA", verbose = FALSE))
  # no co2e_kg_year at all
  expect_null(phase6_lca_diagnostics(
    tibble::tibble(hh_synthetic_id = 1L, lca_status = "ok"),
    iso3 = "USA", verbose = FALSE))
})

test_that("phase6_lca_diagnostics returns a one-row summary for a known iso3", {
  df <- tibble::tibble(
    hh_synthetic_id = 1:3,
    co2e_kg_year = c(8000, 8000, 8000),
    lca_status = rep("ok", 3))
  d <- phase6_lca_diagnostics(df, iso3 = "USA", verbose = FALSE)
  expect_s3_class(d, "data.frame")
  expect_equal(nrow(d), 1L)
  expect_equal(d$iso3, "USA")
  expect_equal(d$mean_kg_co2e_hh, 8000)
  expect_true(d$implied_national_mtco2e > 0)
  expect_true(d$ratio > 0)
})

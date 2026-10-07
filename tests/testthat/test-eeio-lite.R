test_that("attach_eeio_footprint_lite marks cache_missing for uncached regions", {
  # Fake surface for a country in the WA region (uncached in ZA/WF cache)
  surface <- data.frame(
    iso3 = "IND",
    exp_Food.and.beverages = 100, exp_Housing = 50, exp_Energy = 10,
    exp_Transport = 20, exp_Health = 5, exp_ICT = 3,
    exp_Clothing.and.footwear = 4, exp_Water = 2, exp_Education = 8,
    exp_Financial.services = 1, exp_Other.goods.and.services = 15,
    stringsAsFactors = FALSE)
  s2 <- attach_eeio_footprint_lite(surface,
    factor_dir = tempdir())          # empty dir -> no cache
  expect_true("eeio_status" %in% names(s2))
  expect_true(all(s2$eeio_status == "cache_missing"))
})

test_that("attach_eeio_footprint_lite attaches CO2e when cache present", {
  # Only run if WF (Rest of Africa) cache is available
  wf_cache <- path.expand("~/.cache/emburdendata/gcd/exiobase_factors_WF.csv")
  skip_if_not(file.exists(wf_cache), "EXIOBASE WF cache absent")
  surface <- data.frame(
    iso3 = "KEN",
    exp_Food.and.beverages = 200, exp_Housing = 100, exp_Energy = 50,
    exp_Transport = 40, exp_Health = 10, exp_ICT = 5,
    exp_Clothing.and.footwear = 8, exp_Water = 4, exp_Education = 12,
    exp_Financial.services = 3, exp_Other.goods.and.services = 30,
    stringsAsFactors = FALSE)
  s2 <- attach_eeio_footprint_lite(surface)
  expect_equal(unique(s2$eeio_status), "attached")
  expect_true(all(s2$embodied_co2e_kg_hh > 0))
})

test_that("exiobase_region_for_iso3 maps to expected regions", {
  expect_equal(exiobase_region_for_iso3("USA"), "US")
  expect_equal(exiobase_region_for_iso3("DEU"), "DE")
  expect_equal(exiobase_region_for_iso3("ZAF"), "ZA")
  expect_equal(exiobase_region_for_iso3("KEN"), "WF")
  expect_equal(exiobase_region_for_iso3("IND"), "IN")
  expect_equal(exiobase_region_for_iso3("BGD"), "WA")
  expect_equal(exiobase_region_for_iso3("PER"), "WL")
  expect_equal(exiobase_region_for_iso3("BLR"), "WE")
})

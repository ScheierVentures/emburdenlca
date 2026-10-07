# =============================================================================
# emburden <-> dc_e2c3 LCA service bridge (canonical home)
# -----------------------------------------------------------------------------
# EEIO factor data lives in the DC-E2C3 LCA project (host 'wright'), which owns
# the USEEIO / EXIOBASE loaders. Rather than duplicate factor tables into
# emburden, we CALL that project's own loaders over SSH and consume the result.
# The two packages talk; the LCA project stays the single source of factor data.
#
# The ~4-minute EXIOBASE load over tailscale-SSH is flaky, so run_ssa_footprint_pilot.R
# reads a cached factor table (~/.cache/emburdendata/gcd/exiobase_factors_<REGION>.csv)
# first and only falls back to lca_exiobase_factors() when no cache exists.
# =============================================================================

#' Fetch supply-chain GHG factors from the dc_e2c3 LCA service
#'
#' Invokes the LCA project's `load_ghg_factors_from_csv()` on the remote host
#' (in its own virtualenv) and returns the factor table, so emburden never has
#' to carry a copy of the USEEIO factors.
#'
#' @param host SSH host running the LCA project (default "wright").
#' @param lca_dir Path to the LCA project on that host.
#' @return Named numeric vector: NAICS sector code -> kg CO2e per USD (purchaser
#'   price, with margins).
#' @export
lca_ghg_factors <- function(host = "wright",
                            lca_dir = "~/Documents/apps/projects/lca") {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("install 'jsonlite'.")
  py <- paste0(
    "import json,sys; sys.path.insert(0,'src'); ",
    "from dc_e2c3.data.useeio_factors import load_ghg_factors_from_csv as L; ",
    "print(json.dumps(L('data/inputs/useeio/",
    "SupplyChainGHGEmissionFactors_v1.3_CO2e_USD2022.csv')))")
  remote <- sprintf("cd %s && { ./.venv/bin/python -c %s 2>/dev/null || python3 -c %s; }",
                    lca_dir, shQuote(py), shQuote(py))
  out <- tryCatch(
    system2("ssh", c("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
                     "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=20",
                     host, shQuote(remote)), stdout = TRUE, stderr = FALSE),
    error = function(e) character(0))
  js <- out[grepl("^\\{", out)]
  if (!length(js))
    stop("dc_e2c3 LCA service unreachable on host '", host, "'. ",
         "Confirm the host is up and the LCA project's .venv is present.")
  unlist(jsonlite::fromJSON(js[1]))
}

#' Fetch EXIOBASE impact multipliers from the dc_e2c3 LCA service
#'
#' Queries the LCA project's EXIOBASE system (loaded via its own `load_exiobase()`
#' on the remote host) for a set of region x sector pairs in ONE call - the ~5 GB
#' pymrio system is loaded once - so emburden can build multiregional household
#' footprints (e.g. Sub-Saharan Africa) without carrying EXIOBASE locally.
#'
#' EXIOBASE resolves most individual African countries to the "WF" (Rest of Africa)
#' region; South Africa is "ZA". Map an ISO3 to its EXIOBASE region before calling
#' (see [exiobase_region_for_iso3()]).
#'
#' @param pairs A list of `c(region, sector_pattern)` character pairs (EXIOBASE
#'   2-letter region code + a sector name or regex).
#' @param indicator EXIOBASE impact indicator (default "GHG emissions").
#' @param host,lca_dir SSH host and LCA project path.
#' @return Named numeric vector keyed `"region|sector"` -> multiplier (per M.EUR).
#' @export
lca_exiobase_factors <- function(pairs, indicator = "GHG emissions",
                                 host = "wright",
                                 lca_dir = "~/Documents/apps/projects/lca") {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("install 'jsonlite'.")
  pj <- jsonlite::toJSON(lapply(pairs, as.character), auto_unbox = FALSE)
  py <- paste0(
    "import json,sys; sys.path.insert(0,'src'); ",
    "from dc_e2c3.data.exiobase_factors import load_exiobase, query_exiobase; ",
    "io=load_exiobase('external/exiobase', year=2011, system='ixi'); ",
    "P=json.loads('''", pj, "'''); ",
    "print(json.dumps({r+'|'+s: query_exiobase(io, r, s, '''", indicator,
    "''') for r,s in P}))")
  remote <- sprintf("cd %s && ./.venv/bin/python -c %s", lca_dir, shQuote(py))
  out <- tryCatch(
    system2("ssh", c("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=20",
                     "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=20",
                     host, shQuote(remote)), stdout = TRUE, stderr = FALSE),
    error = function(e) character(0))
  js <- out[grepl("^\\{", out)]
  if (!length(js))
    stop("EXIOBASE not available via the LCA service on '", host, "'. ",
         "Has the full load_exiobase() (~5 GB) finished on that host?")
  unlist(jsonlite::fromJSON(js[1]))
}

#' Map an ISO3 country to its EXIOBASE region code
#'
#' EXIOBASE 3 resolves 44 countries plus 5 rest-of-world regions. South Africa is
#' its own region ("ZA"); every other Sub-Saharan country falls under Rest of
#' Africa ("WF"). Now with full 49-region mapping (see function body).
#' @param iso3 Character ISO3 code.
#' @return EXIOBASE 2-letter region code.
#' @export
exiobase_region_for_iso3 <- function(iso3) {
  # EXIOBASE 3.9.4 resolves 44 individual countries plus 5 rest-of-world
  # regions (WA=Asia, WE=Europe, WF=Africa, WL=LatAm, WM=MidEast).
  # ISO3 -> EXIOBASE 2-letter code, extended cover of most GCD countries.
  iso <- toupper(iso3)
  individual <- c(
    # EU-27
    AUT="AT", BEL="BE", BGR="BG", CYP="CY", CZE="CZ", DEU="DE", DNK="DK",
    EST="EE", ESP="ES", FIN="FI", FRA="FR", GRC="GR", HRV="HR", HUN="HU",
    IRL="IE", ITA="IT", LTU="LT", LUX="LU", LVA="LV", MLT="MT", NLD="NL",
    POL="PL", PRT="PT", ROU="RO", SWE="SE", SVN="SI", SVK="SK",
    # Non-EU Europe
    CHE="CH", GBR="GB", NOR="NO", TUR="TR",
    # Americas
    USA="US", CAN="CA", MEX="MX", BRA="BR",
    # Asia
    CHN="CN", IND="IN", IDN="ID", JPN="JP", KOR="KR", TWN="TW", RUS="RU",
    # Africa
    ZAF="ZA",
    # Oceania
    AUS="AU")
  if (!is.na(individual[iso])) return(unname(individual[iso]))
  # RoW dispatch by continent — very coarse, but avoids conflating (say)
  # Kenya with a European rest-of-world factor.
  rest_of_africa <- c("AGO","BDI","BEN","BFA","BWA","CAF","CIV","CMR","COD",
    "COG","DJI","DZA","EGY","ERI","ETH","GAB","GHA","GIN","GMB","GNQ","KEN",
    "LBR","LBY","LSO","MAR","MDG","MLI","MOZ","MRT","MUS","MWI","MYT","NAM",
    "NER","NGA","REU","RWA","SDN","SEN","SLE","SOM","SSD","STP","SWZ","SYC",
    "TCD","TGO","TUN","TZA","UGA","ZMB","ZWE")
  rest_of_asia <- c("AFG","ARM","AZE","BGD","BHR","BRN","BTN","GEO","HKG",
    "IRN","IRQ","ISR","JOR","KAZ","KGZ","KHM","KWT","LAO","LBN","LKA","MAC",
    "MDV","MMR","MNG","MYS","NPL","OMN","PAK","PHL","PNG","PRK","PSE","QAT",
    "SAU","SGP","SYR","THA","TJK","TKM","TLS","UZB","VNM","YEM")
  rest_of_latam <- c("ARG","BHS","BLZ","BOL","CHL","COL","CRI","CUB","DOM",
    "ECU","GRD","GTM","GUY","HND","HTI","JAM","LCA","NIC","PAN","PER","PRY",
    "SLV","SUR","TTO","URY","VCT","VEN")
  rest_of_europe <- c("ALB","AND","BIH","BLR","ISL","LIE","MDA","MKD","MNE",
    "SMR","SRB","UKR","VAT","XKX")
  rest_of_midx    <- character(0)     # handled in rest_of_asia
  if (iso %in% rest_of_africa)  return("WF")
  if (iso %in% rest_of_asia)    return("WA")
  if (iso %in% rest_of_latam)   return("WL")
  if (iso %in% rest_of_europe)  return("WE")
  # Middle-East fallback
  if (iso %in% c("YEM","OMN","SAU","QAT","KWT","BHR","ARE","JOR","LBN","IRQ","SYR"))
    return("WM")
  # Unknown ISO — fall through to global RoW
  "WF"
}

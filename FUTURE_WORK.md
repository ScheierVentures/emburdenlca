# emburdenlca — Future work

## Near-term (next release)

- **Local USEEIO v2 loader** (`R/useeio_local.R`) — load the USEEIOv2.0.1-411 flat CSV release from EPA directly so the US factor path doesn't depend on the SSH-to-`wright` bridge. SSH stays as a secondary path for non-US (EXIOBASE regions) until the cache is complete.
- **EXIOBASE cache fill** (`data-raw/build_exiobase_cache.R`) — loop over 28 uncached GCD regions (WA, WE, WL + 25 individual countries) and persist factors to `~/.cache/emburdendata/lca/exiobase/<iso3>.rds`. Keep file format compatible with `eeio_lite_attach.R`'s current reader. 33 of 61 countries today → 61.
- **Reorganize R/ into subfolders** once the file count grows:
  - `R/attach/` — Phase 6, lite, derived factors
  - `R/service/` — SSH bridge + local loaders
  - `R/global/` — country-level globalization (lca_global.R)

## Medium-term

- **ecoinvent / Brightway2 parity** (`R/ecoinvent_service.R`) — sibling to `global_lca_service.R`, serving process-based LCA factors via a Brightway2 Python backend. Matters for the INFORMS 2026 sensitivity sweep (USEEIO vs EXIOBASE vs ecoinvent) and the Joule manuscript's methods appendix.
- **openLCA / SimaPro adapters** — same pattern.
- **Hardcoded path cleanup in `lca_global.R`** — two `/home/ess/Documents/apps/emburdensynth/docs/...` paths remain for data artifacts. Move those artifacts into `emburdenlca/data/` or configure via env var `EMBURDEN_SYNTH_DOCS`.

## Longer-term

- **Package-level docs site** (`pkgdown`) at `pkg.emburden.org/emburdenlca`.
- **JOSS Wave 2 submission** once the local USEEIO loader + ecoinvent parity are in.
- **CRAN submission** after one release cycle of stable API.

## Dependencies on upstream work

- The DC-E2C3 pipeline (`wright:~/Documents/apps/projects/lca`) continues to own the authoritative USEEIO + EXIOBASE loaders; local parity is a convenience + reliability add, not a replacement.
- `emburdensynth::lca_shims` can be deleted one release cycle after v0.1.0 ships; coordinate with the Joule manuscript's figure-generation code before removing.

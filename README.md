# emburdenlca

**Life-cycle assessment factor service for the emburden ecosystem.**

Spun out of [`emburdensynth`](https://github.com/ScheierVentures/emburdensynth) in October 2026 so one factor-service package can be shared by every ecosystem consumer: the household footprint pipeline (`emburdensynth`), the Compute Carrying Capacity solver for hyperscale data-center siting (upstream Python/Julia DC-E2C3 project on host `wright`), and the global synthesis Joule-target manuscript.

## What's in the box

- **`attach_lca_footprint()`** — Phase 6 attachment that takes `emburdensynth` Phase 5 household output and adds supply-chain + operational embodied-emissions columns. USEEIO v2 NAICS 221100/221200 (US) + EXIOBASE (global), cache-first.
- **`lca_ghg_factors()` / `lca_exiobase_factors()`** — SSH bridge to the DC-E2C3 project on `wright` for factor tables not cached locally.
- **`attach_eeio_footprint_lite()`** — 11-sector EXIOBASE lite attachment for countries beyond the dc_e2c3 remote service.
- **`derive_eeio_factors()`** — derivations for countries outside cached EXIOBASE regions.
- **`globalize_lca_model()`** — Q3.54 country-level LCA layering emergy + electrotech + data-center panels.

## Why spun out

- One package per concern (ecosystem convention).
- Phase 6 is a late-pipeline attachment, not fundamental to the five Phase-1–5 synthesis steps. Co-locating in `emburdensynth` created a false dependency: anyone importing synth got LCA baggage.
- The DC-E2C3 pipeline (Python + Julia GenX + Go InMAP, running on `wright`/`shackleton`) owns the authoritative USEEIO + EXIOBASE loaders; `emburdenlca` is the R-side consumer. Shared across INFORMS 2026, Joule manuscript, and household HEII without each needing to carry LCA code.
- Clean home for the local USEEIO v2 loader + ecoinvent parity work in `FUTURE_WORK.md`.

## Compatibility

- `emburdensynth` retains shim functions (in `emburdensynth/R/lca_shims.R`) that re-export `emburdenlca` symbols for one release cycle. Existing callers do not need to change.
- Caches at `~/.cache/emburdendata/{lca,gcd}/` are shared with `emburdensynth` and the DC-E2C3 pipeline. No cache migration needed.

## Install

```r
# Development version
devtools::install_github("ScheierVentures/emburdenlca")

# From a local checkout
devtools::install_local("/home/ess/Documents/apps/emburdenlca")
```

Depends: `R (>= 4.1)` + `arrow`, `dplyr`, `tibble`, `jsonlite`, plus ecosystem packages `emburdengeo`, `emburdenutil`. `reticulate` + `pymrio` (Suggests) only needed if driving EXIOBASE loads locally rather than via the dc_e2c3 SSH bridge.

## Status

- **v0.1.0** (2026-10-07) — initial spin-out from `emburdensynth`; file-level move with API preserved.
- **Next:** local USEEIO v2 loader (ends SSH-to-wright hard dependency for US); EXIOBASE cache fill (33 of 61 GCD countries today → 61); ecoinvent / Brightway2 parity (`lca_ecoinvent_service.R`).

See `docs/q3_lca_spinout/REPORT.md` for the move narrative, `FUTURE_WORK.md` for the roadmap.

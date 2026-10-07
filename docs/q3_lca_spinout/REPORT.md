# Q3 analysis brief — emburdenlca spin-out from emburdensynth

**Date:** 2026-10-07
**Starts from:** `emburdensynth` v0.2.0 with 5 LCA R files co-located
**Ends at:** `emburdenlca` v0.1.0 sibling package + `emburdensynth` v0.2.1 with shims

## Why

Three forcing functions converged:

1. **Ecosystem convention** — every other emburden package has one concern. LCA code sitting inside `emburdensynth` (whose stated job is the five-phase synthetic microdata pipeline) violated that convention and created an implicit dependency: anyone importing synth got LCA baggage.
2. **Shared consumer list** — the LCA factor service is used by at least three downstream consumers: the household footprint pipeline (`emburdensynth`), the Compute Carrying Capacity solver for INFORMS 2026 (upstream Python DC-E2C3), and the global synthesis Joule manuscript. A single home avoids N-way drift.
3. **Flagged in-house** — `emburdensynth/docs/q3_54_lca_global/REPORT.md` explicitly: *"if a dedicated fleet project for LCA exists elsewhere… re-home `R/lca_global.R` there and turn emburdensynth's copy into a shim."* This is that move.

## What moved

Five R files + two tests, verbatim:

| File | Role |
|---|---|
| `R/phase6_lca_attachment.R` | `attach_lca_footprint()` — Phase 6 USEEIO + EXIOBASE attach |
| `R/global_lca_service.R` | SSH bridge to DC-E2C3 (`lca_ghg_factors`, `lca_exiobase_factors`) |
| `R/eeio_lite_attach.R` | 11-sector EXIOBASE lite attach (`attach_eeio_footprint_lite`) |
| `R/eeio_derived_factors.R` | derivations for countries beyond cached EXIOBASE regions |
| `R/lca_global.R` | Q3.54 country-level LCA layering emergy + electrotech + data-center panels |
| `tests/testthat/test-eeio-lite.R` | existing tests, unchanged |
| `tests/testthat/test-phase6_lca_attachment.R` | existing tests, unchanged |

## Compatibility shim

`emburdensynth/R/lca_shims.R` re-exports every `emburdenlca` symbol used downstream (see shim file for the one-line `::`-re-export per function). Existing callers — the Phase 6 pipeline, Q3.54, the Joule manuscript figures — do not need to change for one release cycle. Shim deletion coordinated via `emburdenlca/FUTURE_WORK.md` and the Joule manuscript's RBuildIgnore.

## What was NOT moved

- `~/.cache/emburdendata/{lca,gcd}/` caches stay in place. Both packages read them.
- `emburdensynth/docs/q3_54_lca_global/REPORT.md` keeps its historical narrative; cross-references `emburdenlca` as the current home.
- Two hardcoded paths inside `lca_global.R` to `/home/ess/Documents/apps/emburdensynth/docs/global_analysis_data/emergy_metrics_extended.rds` and `/home/ess/Documents/apps/emburdensynth/docs/q3_52_prosperity/dashboard.csv` are DATA references (project artifacts, not package code). Flagged in `FUTURE_WORK.md` for later cleanup; current behavior preserved.

## Follow-up (sibling to this move)

See `FUTURE_WORK.md`. Headline items:

- Local USEEIO v2 loader → end the SSH-to-wright hard dependency for US factors.
- EXIOBASE cache fill (33 → 61 GCD countries) → stop falling through to the SSH bridge for 28 regions.
- Ecoinvent / Brightway2 parity → required for the INFORMS 2026 sensitivity sweep.

## Verification

- `devtools::load_all("/home/ess/Documents/apps/emburdenlca")` loads cleanly.
- `devtools::document()` regenerates NAMESPACE.
- `devtools::test()` matches pre-move pass rate (existing failures are not LCA-related).
- `devtools::load_all("/home/ess/Documents/apps/emburdensynth")` still loads with the shim in place.
- A Phase 6 attachment of a small `emburdensynth` run reproduces identical output to the pre-move baseline.
- The committee deck + INFORMS deck both re-render without touching their chunk code (they call `emburdensynth::household_emergy_insecurity()` which internally dispatches through the shim).

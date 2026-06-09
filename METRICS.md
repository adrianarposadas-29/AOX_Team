# AOX_Team — Business Unit Scorecard: Metric Sources

Canonical reference for **where every Business Unit Scorecard tile gets its data**
and the **exact formula** behind it. Aligned to the *ClearPath OS — Data & Design
Standard* and to the live source-of-truth RPC `crm_get_bu_board_l2`.

- **Backend:** Supabase `asdunkqodixbhbohxtuq` (SK Public), PostgREST, anon `SELECT`.
- **Date floor:** all daily views filter `report_date >= 2024-04-01` server-side.
- **Implementation:** [`index.html`](index.html) — `BU_DATA_FILTER`, `fetchBUMetrics`,
  `loadCanonicalAcc`, `loadL2Acc`, `loadL2OtdTatBookings`, `metricsFromAcc*`.
- The L2 true-L2 views were **applied to production 2026-06-09** (see Decision 1); the
  board reads true L2 everywhere, **no rollups**.
- Last verified live: **2026-06-09**.

> A fuller internal PRD lives in `prd/` (git-ignored, local-only). This file is the
> committed, repo-facing summary.

---

## Business units (tabs)

The BU picker is a `<select id="bu-select">`; each option keys into `BU_DATA_FILTER`.

Ten tabs, in this order (mirrors the iOS app). Every tab reads the L2 snapshot keyed on
`business_unit_l2`, exactly matching the iOS app's `crm_get_bu_board_l2`:

| # | Tab (label) | Key | Filter (`business_unit_l2 in …`) |
|---|---|---|---|
| 1 | All | `all` | every non-blank BU (`neq.` blank) — whole-lab total |
| 2 | Crown & Bridge | `crown-bridge` | `Crown & Bridge` |
| 3 | Implant | `implant` | `Implant` |
| 4 | Full Arch | `full-arch` | `Full Arch` |
| 5 | High Esthetics | `high-esthetics` | `High Esthetics` |
| 6 | Printed Product | `digital-product` | `Printed Product` |
| 7 | Analog Denture | `analog-dentures` | `Analog Denture` |
| 8 | Hardware | `hardware` | `Hardware` |
| 9 | Samples | `samples` | `Samples` |
| 10 | Other | `other` | everything not broken out → `Nightguard, Model, Other, Shipping, Alloy` |

**All** and **Other** are aggregate views built with an **exclusion** filter (`notKeys`
→ `not.in.` / `neq.`), **not** a fixed key list — so a revenue-only BU like **Alloy**
(revenue but no shipped cases, absent from `otd_daily_l2`) is still counted. **Nightguard
is folded into Other** (2026-06-09 decision). The blank/unmapped `business_unit_l2` (`''`)
is excluded everywhere, matching the RPC. (PostgREST note: `not.in.("")` ignores a lone
empty string, so single exclusions use `neq.` — see `buL2FilterStr`.) See
[`prd/notes.md`](prd/notes.md). Full Arch and High Esthetics have self-named L2s and were
moved off the canonical L1 views to the L2 snapshot on 2026-06-09 for exact parity
(High Esthetics differed materially — 63 vs 51 shipped on a sample day; Full Arch only
~0.3%). There is **no Ortho BU** — ortho products (clear aligners, retainers, appliances)
live under Printed Product / Analog Denture / High Esthetics. See
[`prd/notes.md`](prd/notes.md) for the All / Other composition.

Live taxonomy (verified): L1 = {`Full Arch`, `High Esthetics`, `Other`,
`Removable`, `Restorative`}; `Restorative` ⊃ {Crown & Bridge, Implant};
`Removable` ⊃ {Analog Denture, Nightguard, Printed Product}; `Other` ⊃ {Hardware,
Samples, Model, Other, Shipping, **Alloy**}. Hardware and Samples get their own tabs;
the rest of `Other` (incl. Nightguard, folded in) rolls up under the **Other** tab. The
blank/unmapped `business_unit_l2` (`''`) is the only thing excluded.

---

## Metric → view → formula

The scorecard **displays four cards** for every BU: **Revenue, OTD, Quality, TAT**.
**Bookings** and **Remake Rate** were removed from the display (2026-06-08); their
view/formula rows are kept below for reference and could be re-added.

| Tile | View(s) | Formula | L1 tabs | L2 tabs |
|---|---|---|---|---|
| **Revenue** | `v_daily_revenue_by_bu` (L1) · `daily_revenue_l2` (L2) | `Σ revenue` (invoice date) | ✅ | ✅ true L2 |
| **OTD** | L1: `v_otd_daily_by_bu` · L2: `otd_daily_l2` | `Σ on_time ÷ Σ shipped` | ✅ | ✅ **true L2** |
| **Quality (Good %)** | `remake_rate_daily_l2` | `1 − Σ lab_fault ÷ Σ shipped` ⚠️ | ✅ | ✅ true L2 |
| **TAT** | L1: `v_tat_daily_by_bu` · L2: `tat_daily_l2` | shipped/case-weighted avg business days | ✅ | ✅ **true L2** |
| ~~Bookings~~ *(removed from display)* | L1: `v_daily_bookings_by_bu` · L2: `v_aox_bookings_daily_l2` | `Σ bookings` (received date) | — | ✅ true L2 |
| ~~Remake~~ *(removed from display)* | `remake_rate_daily_l2` | `Σ remakes ÷ Σ shipped` | — | — |

The L2 views `public.otd_daily_l2`, `public.tat_daily_l2`, and
`public.v_aox_bookings_daily_l2` (defined in
[`sql/2026-06-09_aox_l2_otd_tat_bookings_public_views.sql`](sql/2026-06-09_aox_l2_otd_tat_bookings_public_views.sql))
are **applied to production (2026-06-09)**. There is **no parent-L1 rollup and no
fallback labels**: an L2 tab reads its own true-L2 OTD/TAT/Bookings, and a null value
simply renders "—" (no "n/a" note). The L2 column shape is `case_count` + `tat_sum`
(avg = `Σ tat_sum ÷ Σ case_count`), unlike the L1 view's `avg_tat_business_days`.

**Range caps:** for **Month / Quarter / Year**, ratio metrics (OTD, TAT, Quality)
end at `yest` (last business day) to avoid same-day denominator drift; Revenue ends
at `today`. For **Day / Week**, ratios end at `today` too, so the current period
shows **live** (numbers move through the day as cases ship) instead of blanking out.
**Day-Prior rule** and working-day logic are ported verbatim from the COO board.
**Color (tiles + heat map):** Killian blue good / `#E0625A` bad, compared to the **BU's
target for the active range** when one is set (`buTargetFor` / `thresholdColor`) — so
Full Arch's 12-day TAT reads good against its 15-day target, not bad against the flat
5-day standard. When no target is set, the ClearPath **standard** cut points apply
(OTD ≥ 92%, Quality ≥ 95%, TAT ≤ 5 bd, Remake ≤ 5%). otd/quality: higher is better;
tat/remake: lower is better. The heat-map legend shows the cut point actually in use
(e.g. "≤15 days"). No green/amber, no emoji.

---

## Decision 1 — L2 OTD / TAT / Bookings = true L2, no rollup (applied 2026-06-09)

The ClearPath source-of-truth RPC `crm_get_bu_board_l2` computes true-L2 OTD from
`reporting.otd_daily_l2`, true-L2 TAT from `reporting.tat_daily_l2`, and L2 bookings
from a product-native `public."Line Items"` × `reporting.dim_product` join. The AOX
board runs on the **anon** key, which sees only the `public` schema. `public` already
wrapped two of those reporting tables 1:1 (`public.daily_revenue_l2`,
`public.remake_rate_daily_l2`) but had **no** OTD / TAT / L2-bookings wrapper.

The migration adds exactly those three wrappers so the board reads true L2:
- `public.otd_daily_l2` / `public.tat_daily_l2` — 1:1 pass-throughs.
- `public.v_aox_bookings_daily_l2` — new aggregation replicating the RPC's
  `bookings_agg` **verbatim** (product-native `business_unit_l2`; **not**
  `reporting.fact_invoice_line`, whose location-override attribution diverges from the
  RPC by ~$179k / 25% for Crown & Bridge).

**Applied to production 2026-06-09.** The board now shows **BU-specific true L2** for
OTD / TAT / Bookings on every tab — **no parent-L1 rollup, no rollup labels, no "n/a"
notes** anywhere. Each L2 BU is distinct (e.g. Printed Product 98.8% ≠ Analog Denture
93.4% OTD — they no longer share a `Removable` rollup). A metric with no rows for a
period renders "—". Revenue and Quality are true L2 as before.

Wiring: `loadL2OtdTatBookings()` reads the three true-L2 views; if a read ever fails
the metric is left null ("—") with no fallback. The heat map reads the same true-L2
views directly. The earlier `loadL1RollupOtdBookings()` / rollup-label code was removed.

---

## Decision 2 — Quality denominator = shipped, not total remakes (2026-06-08)

The dashboard computes **`Good % = 1 − lab_fault_remakes ÷ shipped_case_count`**
("share of shipped cases with no lab-fault remake").

This matches what the **live** source-of-truth RPC `crm_get_bu_board_l2` actually
computes (verified 2026-06-09). It **diverges only from the *written* SKDLA doc §5**,
which mandates the *total-remakes* denominator (`1 − lab_fault ÷ total_remakes`). The
written doc assumes that reads high, but **Full Arch breaks the assumption** — ~95% of
its remakes are tagged `Lab Fault` — so the doc formula reads **~5%**. The shipped
denominator reads **~93%** for Full Arch, matching the running source-of-truth code.

Same rows (Full Arch, May 2026: 766 shipped · 56 remakes · 53 lab-fault) →
doc formula **5.4%** vs this board / live RPC **93.1%**.

> The underlying fault-tagging anomaly (so many FA remakes tagged Lab Fault) is worth a
> Scott review independent of this display choice.

---

## Verification (live, May 2026 — full month 2026-05-01 .. 2026-05-31)

Confirmed 2026-06-09 by read-only query against the `reporting` L2 snapshot tables
(the source of truth the iOS `crm_get_bu_board_l2` RPC reads), plus in-browser via
`fetchBUMetrics('2026-05-01','2026-05-31')` per tab; no console errors. **All ten tabs
key on `business_unit_l2`, matching the RPC exactly.**

| Tab | Revenue | Quality (÷ shipped) | OTD | TAT | Bookings |
|---|---|---|---|---|---|
| **All** | **$3,154,213** | 96% | 92.3% | 4.97 bd | $3,278,532 |
| Crown & Bridge | $518,443 | 96% | 91.3% | 4.69 bd | $714,685 |
| Implant | $379,568 | 92% | 84.9% | 11.93 bd | $389,128 |
| Full Arch | $628,088 | 93% | 86.9% | 12.80 bd | — |
| High Esthetics | $697,000 | 92.7% | 84.4% | 7.27 bd | — |
| Printed Product | $381,730 | 98% | 98.8% | 1.25 bd | $384,238 |
| Analog Denture | $145,500 | 95% | 93.4% | 5.46 bd | $159,268 |
| Hardware | $9,696 | 100% | 77% | 14.31 bd | — |
| Samples | $203,400 | 100% | 0% | — | — |
| **Other** | **$190,788** | 98% | 92% | 5.50 bd | $216,029 |

The 8 broken-out tabs + **Other** sum exactly to **All** ($3,154,213) — the tabs
partition the lab with no overlap or gap. **All** = every non-blank `business_unit_l2`
(includes **Alloy** $47,056, a revenue-only BU); **Other** = everything not broken out
(Nightguard $22,807 + Model + Other + Shipping + Alloy). Full Arch and High Esthetics now
read the L2 snapshot (previously the L1 views): Full Arch barely moved (OTD 87.2→86.9),
but High Esthetics shifted to true L2 (OTD 84.8→84.4, Quality ~94→92.7) to match the iOS
app. Bookings read `Line Items` live, so they drift a few $ day-to-day.

**Open item:** real per-operation step lists for the manual ops-entry grid of the tabs
seeded `[]` in `OTD_OPS_BY_BU` (High Esthetics, Implant, Hardware, Samples, All, Other)
— team to supply.

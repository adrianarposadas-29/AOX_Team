# AOX_Team — Business Unit Scorecard: Metric Sources

Canonical reference for **where every Business Unit Scorecard tile gets its data**
and the **exact formula** behind it. Aligned to the *ClearPath OS — Data & Design
Standard* ("the source of truth"), with two deliberate, documented departures
called out below.

- **Backend:** Supabase `asdunkqodixbhbohxtuq` (SK Public), PostgREST, anon `SELECT`.
- **Date floor:** all daily views filter `report_date >= 2024-04-01` server-side.
- **Implementation:** [`index.html`](index.html) — `BU_DATA_FILTER`, `fetchBUMetrics`,
  `loadCanonicalAcc`, `loadL2Acc`, `loadL1RollupOtdBookings`, `metricsFromAcc*`.
- Last verified live: **2026-06-08**.

> A fuller internal PRD lives in `prd/` (git-ignored, local-only). This file is the
> committed, repo-facing summary.

---

## Business units (tabs)

| Tab (label) | Product axis | Filter | `parentL1` (OTD/Bookings rollup) |
|---|---|---|---|
| Full Arch | L1 | `business_unit_l1 = 'Full Arch'` | — (native L1) |
| Crown & Bridge | L2 | `business_unit_l2 = 'Crown & Bridge'` | `Restorative` |
| Printed Product | L2 | `business_unit_l2 = 'Printed Product'` | `Removable` |
| Analog Dentures | L2 | `business_unit_l2 = 'Analog Denture'` | `Removable` |

Live taxonomy (verified): L1 = {`Full Arch`, `High Esthetics`, `Other`,
`Removable`, `Restorative`}; `Restorative` ⊃ {Crown & Bridge, Implant};
`Removable` ⊃ {Analog Denture, Nightguard, Printed Product}.

---

## Metric → view → formula

The scorecard **displays four cards** for every BU: **Revenue, OTD, Quality, TAT**.
**Bookings** and **Remake Rate** were removed from the display (2026-06-08); their
view/formula rows are kept below for reference and could be re-added.

| Tile | View(s) | Formula | L1 tab | L2 tabs |
|---|---|---|---|---|
| **Revenue** | `v_daily_revenue_by_bu` (L1) · `daily_revenue_l2` (L2) | `Σ revenue` (invoice date) | ✅ | ✅ true L2 |
| **OTD** | `v_otd_daily_by_bu` | `Σ on_time ÷ Σ shipped` | ✅ | ➕ **parent-L1 rollup** |
| **Quality (Good %)** | `remake_rate_daily_l2` | `1 − Σ lab_fault ÷ Σ shipped` ⚠️ | ✅ | ✅ true L2 |
| **TAT** | `v_tat_daily_by_bu` | shipped-weighted `avg_tat_business_days` | ✅ | ⚠️ **n/a** (no L2 source) |
| ~~Bookings~~ *(removed from display)* | `v_daily_bookings_by_bu` | `Σ bookings` (received date) | — | — |
| ~~Remake~~ *(removed from display)* | `remake_rate_daily_l2` | `Σ remakes ÷ Σ shipped` | — | — |

**MTD caps:** ratio metrics (OTD, TAT, Quality) end at `yest` (last business
day); Revenue ends at `today`. **Day-Prior rule** and working-day logic are
ported verbatim from the COO board. **Color:** Killian blue good / `#E0625A` bad —
OTD ≥ 92%, TAT ≤ 5 business days, Quality ≥ 95%. No green/amber, no emoji.

---

## Decision 1 — OTD & Bookings at L2 = labeled parent-L1 rollup (2026-06-08)

The source-of-truth doc publishes **OTD and Bookings only at `business_unit_l1`** —
there is no `*_l2` view for either. Rather than show nothing on the three L2 tabs,
each borrows its **parent L1's** number from the canonical L1 views (Crown & Bridge →
`Restorative`; Printed Product / Analog Dentures → `Removable`).

This is an **L1 rollup**, not a BU-specific figure:
- It includes sibling L2s (`Restorative` also covers Implant; `Removable` also covers
  Nightguard).
- **Printed Product and Analog Dentures show identical OTD/Bookings** (both roll up to
  `Removable`) — by construction, not a bug.
- Each tile is labeled "*&lt;parent&gt; L1 rollup*", the heat-map popover title
  appends "(&lt;parent&gt; L1 rollup)", and an on-tile note explains it.
- **Quality and Revenue remain true L2** (so two BUs can share an OTD/Bookings rollup
  yet differ on Quality).

Implemented via `loadL1RollupOtdBookings()` + the `parentL1` key in `BU_DATA_FILTER`.
True per-L2 OTD/TAT/Bookings would need new views (`v_aox_*_l2ad`, drafted in
[`sql/2026-06-05_aox_standard_views.sql`](sql/2026-06-05_aox_standard_views.sql),
not applied — needs Scott's sign-off).

---

## Decision 2 — Quality denominator = shipped, not total remakes (2026-06-08)

The dashboard computes **`Good % = 1 − lab_fault_remakes ÷ shipped_case_count`**
("share of shipped cases with no lab-fault remake").

This **diverges from SKDLA doc §5**, which mandates the *total-remakes* denominator
(`1 − lab_fault ÷ total_remakes`, "share of remakes not lab's fault"). The doc assumes
that reads high, but **Full Arch breaks the assumption** — ~95% of its remakes are
tagged `Lab Fault` — so the doc formula reads **~5%**. The team's sister board uses the
**shipped** denominator and reads **~93%** for Full Arch; this board was switched to
match it. Same `lab_fault_remake_count` source; only the denominator changed.

Same rows (Full Arch, May 2026: 766 shipped · 56 remakes · 53 lab-fault) →
doc formula **5.4%** vs this board **93.1%**.

> The underlying fault-tagging anomaly (so many FA remakes tagged Lab Fault) is worth a
> Scott review independent of this display choice.

---

## Verification (live, May 2026)

**Full Arch (L1):** OTD 87% (DB 87.2%) · TAT 12.8 bd · Quality **93%** (`1−53/766`) ·
Remake 7.3% · shipped 763.

| L2 BU | Revenue (L2) | Quality (L2, ÷ shipped) | Remake (L2) | OTD (rollup) | Bookings (rollup) | TAT |
|---|---|---|---|---|---|---|
| Crown & Bridge | $518,443 | 96% | 6.7% | 90.5% *(Restorative)* | $913,946 *(Restorative)* | n/a |
| Analog Denture | $145,500 | 95% | 5.7% | 97.6% *(Removable)* | $554,020 *(Removable)* | n/a |
| Printed Product | $381,730 | 98% | 1.7% | 97.6% *(Removable)* | $554,020 *(Removable)* | n/a |

Verified in-browser via `fetchBUMetrics('2026-05-01','2026-05-31')` per tab; no console
errors. Revenue was **not** changed by either decision above.

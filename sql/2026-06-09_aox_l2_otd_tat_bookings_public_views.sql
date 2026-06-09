-- ============================================================================
-- APPLIED TO PRODUCTION 2026-06-09 (migration: aox_l2_otd_tat_bookings_public_views).
-- Additive only — three NEW public views, no existing object altered; reversible
-- via DROP VIEW. ClearPath OS Ground Rule #5: mirrors / pass-throughs keep the
-- source name; genuinely new aggregations are named v_*, prefixed with the module.
--
-- WHY THESE EXIST
-- The AOX board's three L2 operational BUs — Crown & Bridge, Analog Denture,
-- Printed Product — plus the two new L2 tabs (Implant, Nightguard) can only show
-- a parent-L1 rollup for OTD (and n/a for TAT), because the board runs on the
-- **anon** key, which sees only the `public` schema. The ClearPath source-of-truth
-- RPC `crm_get_bu_board_l2` computes true-L2 OTD from `reporting.otd_daily_l2`,
-- true-L2 TAT from `reporting.tat_daily_l2`, and L2 bookings from a product-native
-- join over `public."Line Items"` × `reporting.dim_product`. `public` already
-- wraps two of these reporting tables 1:1 (public.daily_revenue_l2,
-- public.remake_rate_daily_l2 — anon SELECT), but has no OTD / TAT / L2-bookings
-- wrapper. These three views add exactly those wrappers so the board can read
-- true-L2 OTD / TAT / Bookings with NO change to the source of truth.
--
-- The front-end (AOX_Team/index.html) is already wired to degrade gracefully:
-- it tries these views and, on a missing-relation error, falls back to today's
-- parent-L1 rollup / n-a. Applying this migration auto-upgrades the board to
-- true L2 with no code change.
--
-- Project: asdunkqodixbhbohxtuq (SK Public).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) public.otd_daily_l2 — 1:1 pass-through of reporting.otd_daily_l2.
--    Mirrors the public.daily_revenue_l2 precedent (same name, anon SELECT).
--    avg OTD = Σ on_time_case_count ÷ Σ shipped_case_count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.otd_daily_l2 AS
SELECT report_date,
       business_unit_l2,
       shipped_case_count,
       on_time_case_count,
       business_unit_l1
FROM reporting.otd_daily_l2;

GRANT SELECT ON public.otd_daily_l2 TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) public.tat_daily_l2 — 1:1 pass-through of reporting.tat_daily_l2.
--    NOTE the column shape differs from the L1 view: this exposes raw
--    case_count + tat_sum, so the average is Σ tat_sum ÷ Σ case_count
--    (the L1 view v_tat_daily_by_bu instead pre-computes avg_tat_business_days).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.tat_daily_l2 AS
SELECT report_date,
       business_unit_l2,
       case_count,
       tat_sum,
       business_unit_l1
FROM reporting.tat_daily_l2;

GRANT SELECT ON public.tat_daily_l2 TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) public.v_aox_bookings_daily_l2 — NEW aggregation (module-prefixed per
--    rule #5). Replicates crm_get_bu_board_l2.bookings_agg VERBATIM: bookings =
--    Σ "Price Net" by "Received Date", attributed on the PRODUCT-NATIVE
--    business_unit_l2 (dim_product), NOT on any location/effective-BU override.
--
--    Deliberately NOT built on reporting.fact_invoice_line: that table's
--    location-override attribution (effective_bu) diverges from the RPC by
--    ~$179k / 25% for Crown & Bridge (verified live, May 2026), so it would NOT
--    match the source of truth. Reads "Line Items" live (a snapshot is not used),
--    exactly as the RPC does.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bookings_daily_l2 AS
SELECT li."Received Date"          AS report_date,
       trim(dp.business_unit_l1)   AS business_unit_l1,
       trim(dp.business_unit_l2)   AS business_unit_l2,
       sum(coalesce(li."Price Net", 0)) AS bookings
FROM public."Line Items" li
JOIN reporting.dim_product dp ON dp.product_id = trim(li."Product Number")
WHERE li."Received Date" >= '2024-04-01'
  AND nullif(trim(dp.business_unit_l2), '') IS NOT NULL
GROUP BY 1, 2, 3;

GRANT SELECT ON public.v_aox_bookings_daily_l2 TO anon, authenticated;

-- ============================================================================
-- RECONCILIATION CHECK (read-only; verified live 2026-06-09 against the
-- `reporting` source tables this proposal wraps). Window: full month
-- 2026-05-01 .. 2026-05-31.
--
--   business_unit_l2 | OTD %  | TAT (bd) | Bookings ($)
--   -----------------+-------+----------+-------------
--   Crown & Bridge   | 91.3  |   4.69   |   714,685
--   Analog Denture   | 93.4  |   5.46   |   159,268
--   Printed Product  | 98.8  |   1.25   |   384,238
--   Implant          | 84.9  |  11.93   |   389,128
--   Nightguard       | 95.4  |   5.14   |    24,979
--
-- (Printed Product & Analog Denture OTD now correctly DIFFER — under the old
--  parent-L1 rollup both read 97.6% because both roll up to Removable.)
-- Bookings drift a few $ day-to-day because "Line Items" is read live.
--
--   SELECT business_unit_l2,
--          round(100.0*sum(on_time_case_count)/nullif(sum(shipped_case_count),0),1) AS otd
--   FROM public.otd_daily_l2
--   WHERE business_unit_l2 IN ('Crown & Bridge','Analog Denture','Printed Product','Implant','Nightguard')
--     AND report_date BETWEEN '2026-05-01' AND '2026-05-31'
--   GROUP BY business_unit_l2;
--
--   SELECT business_unit_l2, round(sum(tat_sum)/nullif(sum(case_count),0),2) AS tat
--   FROM public.tat_daily_l2
--   WHERE business_unit_l2 IN ('Crown & Bridge','Analog Denture','Printed Product','Implant','Nightguard')
--     AND report_date BETWEEN '2026-05-01' AND '2026-05-31'
--   GROUP BY business_unit_l2;
-- ============================================================================

-- ============================================================================
-- APPLIED TO PRODUCTION 2026-06-09 (migration: aox_ops_parity_l2_views).
-- Additive only — four NEW public views, no existing object altered; reversible
-- via DROP VIEW. ClearPath OS Ground Rule #5: pass-throughs keep the source name;
-- genuinely new aggregations are named v_*, prefixed with the module (v_aox_*).
--
-- WHY THESE EXIST  (Decision 3 — align Module 2 to the Operations dashboard)
-- The AOX Business Unit Scorecard was originally aligned to the BU-Board RPC
-- `crm_get_bu_board_l2` (see Decision 1). The team instead wants the board to match
-- the ClearPath **Operations** dashboard (the iOS/desktop "Operations" panel),
-- which is powered by a DIFFERENT RPC, `public.get_dashboard_snapshot`. The two
-- ClearPath sources genuinely disagree for "All / prior month" (verified live, May
-- 2026):
--
--               Module 2 (old, BU-Board parity)   Operations dashboard
--   Revenue     $3,154,213                        $3,138,315
--   OTD         92.3%                              92.8%
--   TAT         4.97 bd                            4.83 bd
--   Quality     96.09%                             96.09%   (same; was a display-round gap)
--
-- Two root causes:
--   1) REVENUE — get_dashboard_snapshot reads reporting.daily_revenue_by_bu, NOT
--      reporting.daily_revenue_l2. The whole $15,898 gap is High Esthetics alone
--      ($696,999.98 in daily_revenue_l2 vs $681,101.82 in daily_revenue_by_bu);
--      every other L2 is penny-identical, and daily_revenue_by_bu carries no
--      blank-L2 revenue.
--   2) OTD / TAT / QUALITY — get_dashboard_snapshot computes these from
--      reporting.fact_case_shipped with the **University market segment EXCLUDED**
--      (an account-level NOT EXISTS against public."Accounts"). The pre-aggregated
--      reporting.{otd,tat,remake_rate}_daily_l2 snapshots INCLUDE University, so
--      they read ~28 extra cases for May (14,819 vs 14,791) and shift OTD/TAT.
--
-- The board runs on the **anon** key (public schema only) and cannot call
-- get_dashboard_snapshot directly (it full-scans fact_case_shipped with no date
-- filter and times out for anon). These four views replicate its math per
-- (report_date, business_unit_l2) so the board reads identical numbers with a
-- date-range filter that pushes down (≈0.4 s / month, ≈1.3 s / year for anon).
--
-- Wiring: AOX_Team/index.html loadL2Acc / loadL2OtdTatBookings / the heat map read
-- these views. Column shapes match the old snapshots 1:1, so only the relation
-- names changed in the front end.
--
-- Project: asdunkqodixbhbohxtuq (SK Public).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) public.daily_revenue_by_bu_l2 — pass-through of reporting.daily_revenue_by_bu
--    exposing the L2 column (the existing public v_daily_revenue_by_bu is L1-only).
--    This is the revenue source get_dashboard_snapshot uses.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.daily_revenue_by_bu_l2 AS
SELECT report_date, business_unit_l1, business_unit_l2,
       revenue, invoice_count, line_count, qualifying_units
FROM reporting.daily_revenue_by_bu;
GRANT SELECT ON public.daily_revenue_by_bu_l2 TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) public.v_aox_otd_daily_l2_ops — OTD by L2, University EXCLUDED.
--    Replicates get_dashboard_snapshot's v_otd: is_shipped_case rows, case-level
--    rollup (bool_or on-time per case/day), University accounts removed.
--    avg OTD = Σ on_time_case_count ÷ Σ shipped_case_count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_otd_daily_l2_ops AS
WITH case_rollup AS (
  SELECT vc.report_date, vc.business_unit_l1, vc.business_unit_l2, vc.case_number,
         bool_or(coalesce(vc.is_on_time_delivery, false)) AS is_on_time
  FROM reporting.fact_case_shipped vc
  WHERE vc.is_shipped_case
    AND vc.report_date IS NOT NULL
    AND vc.report_date >= date '2024-04-01'
    AND nullif(trim(vc.case_number), '') IS NOT NULL
    AND nullif(trim(vc.business_unit_l2), '') IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public."Accounts" acc
         WHERE trim(acc."Account Number") = trim(vc.account_id)
           AND lower(trim(acc."Market Segment")) = 'university')
  GROUP BY vc.report_date, vc.business_unit_l1, vc.business_unit_l2, vc.case_number
)
SELECT report_date, business_unit_l1, business_unit_l2,
       count(*)::int                              AS shipped_case_count,
       count(*) FILTER (WHERE is_on_time)::int    AS on_time_case_count
FROM case_rollup
GROUP BY report_date, business_unit_l1, business_unit_l2;
GRANT SELECT ON public.v_aox_otd_daily_l2_ops TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) public.v_aox_tat_daily_l2_ops — TAT by L2, University EXCLUDED.
--    Column shape matches the old public.tat_daily_l2: raw case_count + tat_sum,
--    so the average is Σ tat_sum ÷ Σ case_count. (fact_case_shipped is 1 row per
--    case for non-null TAT, so this equals get_dashboard_snapshot's per-day avg.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_tat_daily_l2_ops AS
SELECT vc.report_date, vc.business_unit_l1, vc.business_unit_l2,
       count(DISTINCT vc.case_number)::int  AS case_count,
       sum(vc.tat_business_days)::numeric   AS tat_sum
FROM reporting.fact_case_shipped vc
WHERE vc.report_date IS NOT NULL
  AND vc.report_date >= date '2024-04-01'
  AND vc.tat_business_days IS NOT NULL
  AND nullif(trim(vc.business_unit_l2), '') IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM public."Accounts" acc
       WHERE trim(acc."Account Number") = trim(vc.account_id)
         AND lower(trim(acc."Market Segment")) = 'university')
GROUP BY vc.report_date, vc.business_unit_l1, vc.business_unit_l2;
GRANT SELECT ON public.v_aox_tat_daily_l2_ops TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) public.v_aox_remake_daily_l2_ops — remake / quality by L2, University
--    EXCLUDED. Column shape matches public.remake_rate_daily_l2.
--    Good % = 1 − Σ lab_fault_remake_count ÷ Σ shipped_case_count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_remake_daily_l2_ops AS
SELECT vc.report_date, vc.business_unit_l1, vc.business_unit_l2,
       count(DISTINCT vc.case_number)::int AS shipped_case_count,
       count(DISTINCT vc.case_number) FILTER (WHERE vc.is_remake)::int AS remake_case_count,
       count(DISTINCT vc.case_number) FILTER (
            WHERE vc.is_remake
              AND lower(coalesce(vc.remake_fault, '')) LIKE '%lab%')::int AS lab_fault_remake_count
FROM reporting.fact_case_shipped vc
WHERE vc.report_date IS NOT NULL
  AND vc.report_date >= date '2024-04-01'
  AND nullif(trim(vc.business_unit_l2), '') IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM public."Accounts" acc
       WHERE trim(acc."Account Number") = trim(vc.account_id)
         AND lower(trim(acc."Market Segment")) = 'university')
GROUP BY vc.report_date, vc.business_unit_l1, vc.business_unit_l2;
GRANT SELECT ON public.v_aox_remake_daily_l2_ops TO anon, authenticated;

-- ============================================================================
-- RECONCILIATION (read-only; verified live 2026-06-09, full month
-- 2026-05-01 .. 2026-05-31, "All" = every non-blank business_unit_l2). These
-- now equal the Operations dashboard panel exactly:
--
--   Revenue  $3,138,315   (daily_revenue_by_bu_l2)
--   Shipped  14,791       (v_aox_otd_daily_l2_ops)
--   OTD      92.85%  -> 92.8%
--   TAT      4.83 bd -> 4.8
--   Quality  96.09%  -> 96.1%
--
--   SELECT sum(revenue) FROM public.daily_revenue_by_bu_l2
--    WHERE report_date BETWEEN '2026-05-01' AND '2026-05-31'
--      AND nullif(trim(business_unit_l2),'') IS NOT NULL;          -- 3138314.65
--   SELECT round(100.0*sum(on_time_case_count)/sum(shipped_case_count),2)
--     FROM public.v_aox_otd_daily_l2_ops
--    WHERE report_date BETWEEN '2026-05-01' AND '2026-05-31';      -- 92.85
-- ============================================================================

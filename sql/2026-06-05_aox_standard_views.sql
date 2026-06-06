-- ============================================================================
-- PROPOSAL ONLY — DO NOT APPLY WITHOUT SCOTT'S SIGN-OFF
-- ClearPath OS Ground Rules #2/#3/#5: never alter an existing object; if you
-- need a NEW view, propose the SQL first, get sign-off, THEN apply via
-- apply_migration. Name new views v_*, prefixed with the module name.
--
-- WHY THESE EXIST (and why nothing else is created):
-- The AOX dashboard's metrics now read the EXISTING canonical views per the
-- standard (v_otd_daily_by_bu, v_tat_daily_by_bu, v_remake_rate_daily_by_bu,
-- remake_rate_daily_l2, v_daily_revenue_by_bu, v_daily_bookings_by_bu), keyed
-- by business_unit_l1. Those reconcile with the COO board and need no changes.
--
-- The ONLY thing the standard does not provide is an analog/digital breakdown.
-- Verified live 2026-06-05: analog/digital is a real independent axis on
-- public."Cases" ("Analog Digital") that is NOT encoded in business_unit_l1 or
-- business_unit_l2 (e.g. Full Arch has 8,440 Digital + 1,133 Analog cases; its
-- L2 is just "Full Arch"). The AOX digital-product / analog-dentures tabs need
-- it, so per rule #5 we add three NEW module-prefixed views below.
--
-- These mirror the canonical fact logic VERBATIM and add ONE group key
-- (analog_digital), so summing across analog_digital reconciles back to the
-- canonical L1 views by construction (same facts, same filters).
-- The existing bu_health_daily / bu_revenue_daily are left UNTOUCHED.
--
-- ASSUMPTION to confirm with Scott: public."Cases" is one row per "Case Number"
-- (the DISTINCT subquery guards against fan-out regardless).
-- Project: asdunkqodixbhbohxtuq (SK Public).
-- ============================================================================

-- Reusable analog/digital lookup (one row per case)
--   (inlined in each view below as a DISTINCT subquery)

-- ---------------------------------------------------------------------------
-- 1) v_aox_bu_health_ad — OTD / TAT / Remake / lab-fault Quality, by a/d
--    Sum across analog_digital == v_otd_daily_by_bu / v_remake_rate_daily_by_bu.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_health_ad AS
SELECT
    fcs.report_date,
    fcs.business_unit_l1,
    ad.analog_digital,
    count(DISTINCT fcs.case_number)::numeric AS shipped_case_count,
    count(DISTINCT CASE WHEN fcs.is_on_time_delivery IS TRUE
                        THEN fcs.case_number END)::numeric AS on_time_case_count,
    count(DISTINCT CASE WHEN fcs.is_remake
                        THEN fcs.case_number END)::numeric AS remake_case_count,
    count(DISTINCT CASE WHEN fcs.is_remake AND fcs.remake_fault = 'Lab Fault'
                        THEN fcs.case_number END)::numeric AS lab_fault_remake_count,
    avg(fcs.tat_business_days::double precision)
        FILTER (WHERE fcs.tat_business_days IS NOT NULL) AS avg_tat_business_days
FROM reporting.fact_case_shipped fcs
LEFT JOIN (
    SELECT DISTINCT "Case Number" AS case_number, "Analog Digital" AS analog_digital
    FROM public."Cases"
) ad ON ad.case_number = fcs.case_number
WHERE fcs.report_date IS NOT NULL
  AND fcs.report_date >= '2024-04-01'::date
  AND fcs.business_unit_l1 IS NOT NULL
  AND btrim(fcs.business_unit_l1) <> ''
GROUP BY fcs.report_date, fcs.business_unit_l1, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_health_ad TO anon;

-- ---------------------------------------------------------------------------
-- 2) v_aox_bu_revenue_ad — revenue by invoice date, by a/d
--    Sum across analog_digital == v_daily_revenue_by_bu.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_revenue_ad AS
SELECT
    fil.report_date,
    fil.business_unit_l1,
    ad.analog_digital,
    sum(fil.line_revenue) AS revenue
FROM reporting.fact_invoice_line fil
LEFT JOIN (
    SELECT DISTINCT "Case Number" AS case_number, "Analog Digital" AS analog_digital
    FROM public."Cases"
) ad ON ad.case_number = fil.case_number
WHERE fil.report_date IS NOT NULL
  AND fil.report_date >= '2024-04-01'::date
  AND fil.business_unit_l1 IS NOT NULL
  AND btrim(fil.business_unit_l1) <> ''
GROUP BY fil.report_date, fil.business_unit_l1, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_revenue_ad TO anon;

-- ---------------------------------------------------------------------------
-- 3) v_aox_bu_bookings_ad — bookings by received date, by a/d
--    received_date aliased to report_date to match v_daily_bookings_by_bu.
--    Sum across analog_digital == v_daily_bookings_by_bu.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_bookings_ad AS
SELECT
    fil.received_date AS report_date,
    fil.business_unit_l1,
    ad.analog_digital,
    sum(fil.line_revenue) AS bookings
FROM reporting.fact_invoice_line fil
LEFT JOIN (
    SELECT DISTINCT "Case Number" AS case_number, "Analog Digital" AS analog_digital
    FROM public."Cases"
) ad ON ad.case_number = fil.case_number
WHERE fil.received_date IS NOT NULL
  AND fil.received_date >= '2024-04-01'::date
  AND fil.business_unit_l1 IS NOT NULL
  AND btrim(fil.business_unit_l1) <> ''
GROUP BY fil.received_date, fil.business_unit_l1, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_bookings_ad TO anon;

-- ============================================================================
-- RECONCILIATION CHECK (run after applying): summing a/d must equal canonical.
--   SELECT round(100*sum(on_time_case_count)/sum(shipped_case_count),1)
--   FROM public.v_aox_bu_health_ad
--   WHERE business_unit_l1='Full Arch'
--     AND report_date BETWEEN '2026-05-01' AND '2026-05-31';   -- expect ~87.2
--   -- compare to v_otd_daily_by_bu for the same L1/period.
-- ============================================================================

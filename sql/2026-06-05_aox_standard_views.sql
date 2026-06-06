-- ============================================================================
-- PROPOSAL ONLY — DO NOT APPLY WITHOUT SCOTT'S SIGN-OFF
-- ClearPath OS Ground Rules #2/#3/#5: never alter an existing object; if you
-- need a NEW view, propose the SQL first, get sign-off, THEN apply via
-- apply_migration. Name new views v_*, prefixed with the module name.
--
-- WHY THESE EXIST
-- The AOX board's three operational BUs — Crown & Bridge, Analog Denture, and
-- Printed Product (the tab labeled "Digital Product") — are defined by product
-- **business_unit_l2** (the source-of-truth axis behind huddle_business_units),
-- NOT by business_unit_l1 or the analog/digital flag. Verified live 2026-06-05:
--   Restorative L2 = {Crown & Bridge, Implant}
--   Removable  L2 = {Analog Denture, Nightguard, Printed Product}
-- The canonical daily views split by L1 only (plus remake_rate_daily_l2 /
-- daily_revenue_l2 which carry L2). There is no canonical L2-level view for
-- OTD / TAT / Bookings, and none for the analog/digital sub-split. Per rule #5
-- we add three NEW module-prefixed views, grouped by L1 × L2 × analog_digital.
--
-- RECONCILIATION (by construction — same facts, same filters as canonical):
--   sum over analog_digital, for a given L2  == that L2's totals
--       (matches daily_revenue_l2 / remake_rate_daily_l2 for $ / remake / quality)
--   sum over L2 and analog_digital, for an L1 == the canonical L1 by_bu views
-- The existing bu_health_daily / bu_revenue_daily are left UNTOUCHED.
--
-- ASSUMPTION to confirm with Scott: public."Cases" is one row per "Case Number"
-- (the DISTINCT subquery guards against fan-out regardless).
-- Project: asdunkqodixbhbohxtuq (SK Public).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) v_aox_bu_health_l2ad — OTD / TAT / Remake / lab-fault Quality
--    by report_date × business_unit_l1 × business_unit_l2 × analog_digital
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_health_l2ad AS
SELECT
    fcs.report_date,
    fcs.business_unit_l1,
    fcs.business_unit_l2,
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
GROUP BY fcs.report_date, fcs.business_unit_l1, fcs.business_unit_l2, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_health_l2ad TO anon;

-- ---------------------------------------------------------------------------
-- 2) v_aox_bu_revenue_l2ad — revenue by invoice date × L1 × L2 × a/d
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_revenue_l2ad AS
SELECT
    fil.report_date,
    fil.business_unit_l1,
    fil.business_unit_l2,
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
GROUP BY fil.report_date, fil.business_unit_l1, fil.business_unit_l2, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_revenue_l2ad TO anon;

-- ---------------------------------------------------------------------------
-- 3) v_aox_bu_bookings_l2ad — bookings by received date × L1 × L2 × a/d
--    received_date aliased to report_date to match v_daily_bookings_by_bu.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_aox_bu_bookings_l2ad AS
SELECT
    fil.received_date AS report_date,
    fil.business_unit_l1,
    fil.business_unit_l2,
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
GROUP BY fil.received_date, fil.business_unit_l1, fil.business_unit_l2, ad.analog_digital;

GRANT SELECT ON public.v_aox_bu_bookings_l2ad TO anon;

-- ============================================================================
-- RECONCILIATION CHECK (run after applying). Expected (May 2026):
--   Crown & Bridge : shipped 5544, OTD 91.8%, TAT 4.66, remake 6.7%, rev 518,443
--   Analog Denture : shipped 1053, OTD 93.0%, TAT 5.92, remake 5.4%, rev 145,500
--   Printed Product: shipped 4416, OTD 98.9%, TAT 1.24, remake 1.7%, rev 381,730
--
--   SELECT business_unit_l2, sum(shipped_case_count) s,
--          round(100*sum(on_time_case_count)/sum(shipped_case_count),1) otd
--   FROM public.v_aox_bu_health_l2ad
--   WHERE business_unit_l2 IN ('Crown & Bridge','Analog Denture','Printed Product')
--     AND report_date BETWEEN '2026-05-01' AND '2026-05-31'
--   GROUP BY business_unit_l2;
-- ============================================================================

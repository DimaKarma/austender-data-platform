/*
  rpt_contracts — the base reporting view over the star, one row per contract.

  This is the consumption layer: it resolves the supplier entity, applies the
  data-quality caveats the raw star only *flags*, and defines the two spend
  measures once so every report agrees. An analyst querying mart cannot
  accidentally sum the wrong thing, because the wrong thing is not exposed here.

  is_attributable is the single gate. A contract's value is attributable to a
  named supplier only when both hold:
    * the stated ABN is not an agency's own ABN standing in (the register's
      verdict, via supplier_abn_is_placeholder), and
    * the supplier is not a known non-company channel — FMS, travel panels —
      which have no ABN for the register to catch (the known_non_suppliers seed).
*/

with fct as (
    select * from {{ ref('fct_contracts') }}
),

supplier as (
    select
        supplier_key,
        supplier_entity_key,
        supplier_entity_name,
        supplier_name,
        supplier_abn,
        abn_source,
        supplier_abn_is_placeholder,
        {{ normalize_name('supplier_name') }} as supplier_name_norm
    from {{ ref('dim_supplier') }}
),

non_supplier as (
    select normalized_name, category from {{ ref('known_non_suppliers') }}
),

agency as (
    select agency_key, agency_name, agency_abn from {{ ref('dim_agency') }}
),

category as (
    select category_key, category_name, category_unspsc from {{ ref('dim_category') }}
),

dates as (
    select date_key, full_date, year from {{ ref('dim_date') }}
)

select
    f.contract_id,
    f.source_notice_id,
    f.amendment_no,

    -- supplier, resolved to its real entity
    s.supplier_entity_key,
    s.supplier_entity_name,
    s.supplier_name,
    s.supplier_abn,
    -- 'stated' / 'abr_name_match' / 'none': whether the supplier's ABN was on the
    -- contract or suggested from the register by name. Filter to 'stated' for
    -- certain-only analysis.
    s.abn_source,

    -- agency and category
    a.agency_name,
    a.agency_abn,
    c.category_name,

    -- time
    f.publish_date,
    d.year as publish_year,
    f.contract_start_date,
    f.contract_end_date,
    f.duration_days,
    -- a contract is "active" if it has started and not yet ended as of the run
    coalesce(
        f.contract_start_date <= current_date()
        and (f.contract_end_date is null or f.contract_end_date >= current_date()),
        false
    ) as is_active,

    -- the measure, and the one gate that governs how it may be summed
    f.contract_value,
    coalesce(
        not s.supplier_abn_is_placeholder and ns.normalized_name is null,
        false
    ) as is_attributable,

    -- why a row is not attributable, for drill-down and trust
    case
        when s.supplier_abn_is_placeholder then 'agency ABN placeholder'
        when ns.normalized_name is not null then 'non-supplier: ' || ns.category
    end as unattributable_reason

from fct as f
left join supplier as s on f.supplier_key = s.supplier_key
left join non_supplier as ns on s.supplier_name_norm = ns.normalized_name
left join agency as a on f.agency_key = a.agency_key
left join category as c on f.category_key = c.category_key
left join dates as d on f.publish_date_key = d.date_key

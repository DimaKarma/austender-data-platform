/*
  dim_supplier — the "Supplier" dimension.

  Grain: one row per supplier, identified the way the source identifies it — ABN
  when it has one, otherwise name (see macros/business_keys.sql).

  Name is an attribute, not part of the key. 6,942 ABNs appear under more than
  one spelling, so keying on the label turned ~35,147 real suppliers into 56,367
  dimension rows and made any "count of suppliers" 60% too high. Where spellings
  differ, the most recently published one wins — the same "latest version of the
  truth" rule the fact uses for amendments.
*/
{{ config(materialized='table') }}

with suppliers as (
    select
        supplier_business_key,
        supplier_name,
        supplier_abn,
        publish_date
    from {{ ref('slv_contracts') }}
    where supplier_name is not null
),

latest as (
    select
        supplier_business_key,
        supplier_name,
        supplier_abn
    from suppliers
    qualify row_number() over (
        partition by supplier_business_key
        -- supplier_name breaks ties so the winner is deterministic: without it,
        -- two spellings published the same day would make the build unstable.
        order by publish_date desc nulls last, supplier_name
    ) = 1
)

select
    {{ dbt_utils.generate_surrogate_key(['supplier_business_key']) }} as supplier_key,
    supplier_business_key,
    supplier_name,
    supplier_abn
from latest

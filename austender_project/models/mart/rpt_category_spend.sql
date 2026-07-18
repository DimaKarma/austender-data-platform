/*
  rpt_category_spend — spend per procurement category (UNSPSC), by year.

  dim_category was in the star but had no report. Same two-measure discipline as
  the other rpt_* views: total_spend reconciles to the fact, attributable_spend
  drops placeholder ABNs and non-supplier channels.
*/

with c as (
    select * from {{ ref('rpt_contracts') }}
)

select
    category_name,
    publish_year,
    count(*)                                                       as contracts,
    count(distinct supplier_entity_key)                            as suppliers,
    sum(contract_value)                                            as total_spend,
    sum(case when is_attributable then contract_value else 0 end)  as attributable_spend
from c
where category_name is not null
group by category_name, publish_year

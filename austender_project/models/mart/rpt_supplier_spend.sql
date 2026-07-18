/*
  rpt_supplier_spend — spend per real supplier, the report that was most wrong
  before the entity rollup and the register join.

  Grain: one row per supplier entity (supplier_entity_key), so Hays is one line,
  not 77. Both measures are carried:
    * total_spend       — every contract on this entity; reconciles to the raw total
    * attributable_spend — only the contracts attributable to a named supplier

  For a "top suppliers" list, order by attributable_spend and the FMS programme
  ($10.1B) and the agency-ABN placeholders drop out on their own, instead of
  leading the table.
*/

with c as (
    select * from {{ ref('rpt_contracts') }}
)

select
    supplier_entity_key,
    max(supplier_entity_name) as supplier_entity_name,
    -- an entity is attributable or not as a whole (placeholder and non-supplier
    -- rows form their own name-keyed entities), but aggregate defensively.
    booland_agg(is_attributable) as is_attributable,

    count(*) as contracts,
    sum(contract_value) as total_spend,
    sum(case when is_attributable then contract_value else 0 end) as attributable_spend
from c
group by supplier_entity_key

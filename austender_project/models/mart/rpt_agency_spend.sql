/*
  rpt_agency_spend — spend per buying agency, by year.

  Grain: one row per (agency, publish_year). Both measures again — the gap
  between them is a per-agency, per-year measure of how much of that agency's
  spend runs through placeholder ABNs or non-supplier channels. It is largest for
  Defence and the DMO, whose FMS and inter-agency rows are exactly the
  unattributable ones.
*/

with c as (
    select * from {{ ref('rpt_contracts') }}
)

select
    agency_name,
    publish_year,
    count(*) as contracts,
    count(distinct supplier_entity_key) as suppliers,
    sum(contract_value) as total_spend,
    sum(case when is_attributable then contract_value else 0 end) as attributable_spend
from c
where agency_name is not null
group by agency_name, publish_year

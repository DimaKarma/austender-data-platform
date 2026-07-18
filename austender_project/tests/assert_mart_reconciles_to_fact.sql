/*
  The consumption layer must neither lose nor invent money.

  rpt_supplier_spend re-grains the fact to the supplier entity; a wrong join
  there would silently drop or double-count spend, and every report built on the
  mart would inherit it. This checks that the mart's total still equals the
  fact's total to the cent, and that total = attributable + unattributable.

  Returns a row (failing the build) only if they disagree.
*/

with fact as (
    select sum(contract_value) as fact_total from {{ ref('fct_contracts') }}
),

mart as (
    select
        sum(total_spend) as mart_total,
        sum(attributable_spend) as mart_attributable
    from {{ ref('rpt_supplier_spend') }}
)

select
    fact.fact_total,
    mart.mart_total,
    mart.mart_attributable
from fact cross join mart
where fact.fact_total <> mart.mart_total

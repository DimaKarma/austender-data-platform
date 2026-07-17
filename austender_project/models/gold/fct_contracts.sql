/*
  fct_contracts — the "Contract" fact table.
  Grain: one row = one contract_id.
  Incremental: re-runs append only newly published contracts, demonstrating
  dbt's incremental pattern.
  Foreign keys to every dimension use surrogate keys built with the same
  formula as the dim models.
*/
{{ config(
    materialized='incremental',
    unique_key='contract_id',
    incremental_strategy='merge'
) }}

with contracts as (
    select * from {{ ref('slv_contracts') }}

    {% if is_incremental() %}
      -- only contracts newer than the latest one already loaded
      where publish_date > (select max(publish_date) from {{ this }})
    {% endif %}
)

select
    -- degenerate dimension (the contract key carried on the fact)
    contract_id,

    -- foreign keys to the dimensions
    {{ dbt_utils.generate_surrogate_key(['supplier_name', 'supplier_abn']) }} as supplier_key,
    {{ dbt_utils.generate_surrogate_key(['agency_name', 'agency_abn']) }}     as agency_key,
    {{ dbt_utils.generate_surrogate_key(['category_name', 'category_unspsc']) }} as category_key,
    cast(to_char(publish_date, 'YYYYMMDD') as integer)                        as publish_date_key,

    -- measures
    contract_value,
    duration_days,

    -- attributes
    procurement_method,
    publish_date,
    contract_start_date,
    contract_end_date
from contracts

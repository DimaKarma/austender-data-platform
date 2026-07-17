/*
  dim_supplier — the "Supplier" dimension.
  Surrogate key via dbt_utils.generate_surrogate_key.
  Grain: one row per unique (supplier_name, supplier_abn) pair.
*/
{{ config(materialized='table') }}

with suppliers as (
    select distinct
        supplier_name,
        supplier_abn
    from {{ ref('slv_contracts') }}
    where supplier_name is not null
)

select
    {{ dbt_utils.generate_surrogate_key(['supplier_name', 'supplier_abn']) }} as supplier_key,
    supplier_name,
    supplier_abn
from suppliers

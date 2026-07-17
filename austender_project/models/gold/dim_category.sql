/*
  dim_category — the "Procurement category" dimension (UNSPSC).
*/
{{ config(materialized='table') }}

with categories as (
    select distinct
        category_name,
        category_unspsc
    from {{ ref('slv_contracts') }}
    where category_name is not null
)

select
    {{ dbt_utils.generate_surrogate_key(['category_name', 'category_unspsc']) }} as category_key,
    category_name,
    category_unspsc
from categories

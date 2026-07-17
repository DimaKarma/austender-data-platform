/*
  dim_agency — the "Government agency / buyer" dimension.
  Grain: one row per unique (agency_name, agency_abn) pair.
*/
{{ config(materialized='table') }}

with agencies as (
    select distinct
        agency_name,
        agency_abn
    from {{ ref('slv_contracts') }}
    -- No null filter: Silver coalesces missing names to 'Unknown', so every
    -- fact row has a matching dimension row.
)

select
    {{ dbt_utils.generate_surrogate_key(['agency_name', 'agency_abn']) }} as agency_key,
    agency_name,
    agency_abn
from agencies

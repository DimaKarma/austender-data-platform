/*
  fct_contracts — the "Contract" fact table.

  Grain: one row per contract, holding its latest version.

  AusTender publishes amendments as separate notices (413292, 413292-A1,
  413292-A2 — see macros/contract_amendment.sql). Carrying each notice as its
  own fact row triple-counts amended contracts: measured against this extract,
  that overstated total spend by $11.17B (5.8%). The chain is therefore collapsed
  to its latest amendment, which is the contract as it currently stands.

  Silver deliberately keeps every notice at source grain; this is where the
  business grain is chosen.

  Incremental: re-runs process only contracts touched since the last build.
*/
{{ config(
    materialized='incremental',
    unique_key='contract_id',
    incremental_strategy='merge'
) }}

with versions as (
    select
        s.*,
        {{ base_contract_id('s.contract_id') }} as base_contract_id,
        {{ amendment_no('s.contract_id') }}     as amendment_no
    from {{ ref('slv_contracts') }} s

    {% if is_incremental() %}
      -- Rank against *every* known version of a touched contract, not just the
      -- new arrivals: an amendment ingested late must still be compared with the
      -- versions already in the fact, or it could win on its own and overwrite a
      -- newer one.
      --
      -- The watermark reads loaded_at (ingestion time), never publish_date: an
      -- amendment keeps the original's publish_date, so a business-date filter
      -- could never let one through.
      where {{ base_contract_id('s.contract_id') }} in (
          select distinct {{ base_contract_id('contract_id') }}
          from {{ ref('slv_contracts') }}
          where loaded_at > (select max(loaded_at) from {{ this }})
      )
    {% endif %}
),

latest as (
    select
        *,
        -- Advance the watermark using the whole chain, not the winning row: when
        -- a late amendment loses the ranking, the fact must still record that it
        -- was seen, or the same rows would be re-selected on every future run.
        max(loaded_at) over (partition by base_contract_id) as chain_loaded_at
    from versions
    qualify row_number() over (
        partition by base_contract_id
        order by amendment_no desc, loaded_at desc
    ) = 1
)

select
    -- degenerate dimension: the contract, not the notice
    base_contract_id                                                          as contract_id,

    -- which notice this row is sourced from, and how many amendments deep it is
    contract_id                                                               as source_notice_id,
    amendment_no,

    -- foreign keys to the dimensions
    {{ dbt_utils.generate_surrogate_key(['supplier_business_key']) }}         as supplier_key,
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
    contract_end_date,

    -- audit: the watermark the incremental predicate above reads
    chain_loaded_at                                                           as loaded_at
from latest

/*
  stg_contracts — the staging layer.
  Renames to snake_case, casts types, cleans strings.
  No business logic, no aggregation. Materialized as a view.
*/
with source as (
    select * from {{ source('bronze', 'raw_contract_data') }}
),

renamed as (
    select
        -- key
        {{ clean_string('cnid') }}                          as contract_id,

        -- dimensions (strings)
        {{ clean_string('agencyname') }}                    as agency_name,
        {{ clean_string('agencyabn') }}                     as agency_abn,
        {{ clean_string('suppliername') }}                  as supplier_name,
        -- '0' is the source's sentinel for "foreign supplier, no ABN": those
        -- 6,693 rows are exactly the ones whose ABN is not 11 digits. Collapse
        -- it to NULL here so "missing" has one representation downstream.
        nullif({{ clean_string('supplierabn') }}, '0')      as supplier_abn,
        {{ clean_string('supplierid') }}                    as supplier_source_id,
        {{ clean_string('category') }}                      as category_name,
        {{ clean_string('categoryunspsc') }}                as category_unspsc,
        {{ clean_string('procurementmethod') }}             as procurement_method,
        {{ clean_string('description') }}                   as contract_description,
        {{ clean_string('sourceurl') }}                     as source_url,

        -- measure
        try_cast(value as number(18, 2))                    as contract_value,

        -- dates (source format is YYYY-MM-DD)
        try_to_date(publishdate,   'YYYY-MM-DD')            as publish_date,
        try_to_date(contractstart, 'YYYY-MM-DD')            as contract_start_date,
        try_to_date(contractend,   'YYYY-MM-DD')            as contract_end_date,

        -- audit
        _loaded_at                                          as loaded_at,
        _source_file                                        as source_file
    from source
)

select * from renamed

/*
  stg_abr_entity — staging over the ABR bulk extract.
  Renames, cleans strings, types the date. No business logic.

  Materialized as a table rather than a view: the source is ~20.4M rows and every
  build of dim_supplier joins it, so paying once beats scanning Bronze each time.
*/
{{ config(materialized='table') }}

with source as (
    select * from {{ source('abr_bronze', 'raw_abr_entity') }}
),

renamed as (
    select
        {{ clean_string('abn') }}                       as abn,
        {{ clean_string('abn_status') }}                as abn_status,
        try_to_date(abn_status_from_date, 'YYYYMMDD')   as abn_status_from_date,
        {{ clean_string('entity_type_ind') }}           as entity_type_ind,
        {{ clean_string('entity_type_text') }}          as entity_type_text,
        {{ clean_string('entity_name') }}               as entity_name,
        {{ clean_string('state') }}                     as state,
        {{ clean_string('postcode') }}                  as postcode,

        -- The register spells the verdict out in words, so read it rather than
        -- hardcoding type codes: CGE/SGE/LGE/TGE and friends all carry
        -- "Government" in the text, while FPT — which looks governmental — is
        -- Family Partnership.
        coalesce(entity_type_text ilike '%Government%', false) as is_government_entity,

        _loaded_at                                      as loaded_at,
        _source_file                                    as source_file
    from source
    where abn is not null
)

select * from renamed

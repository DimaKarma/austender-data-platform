/*
  stg_abr_entity — one row per ABN with its canonical (MAIN) name and attributes.

  Bronze now holds several rows per ABN (one per name — main, trading, other), so
  this filters to name_type = 'MAIN' to keep exactly one row per ABN. That keeps
  the dim_supplier enrichment join at one-to-one; the alternate names are exposed
  separately by stg_abr_names for matching. Guarded with qualify in case a record
  ever yields more than one MAIN.

  Materialized as a table in prod (dim_supplier joins it every build), but a VIEW
  on the ci target so a PR run does not copy ~20.4M rows into CI_GOLD's upstream —
  the join still resolves through the view. Interim until Slim CI.
*/
{{ config(materialized=('view' if target.name == 'ci' else 'table')) }}

with source as (
    select * from {{ source('abr_bronze', 'raw_abr_entity') }}
    where name_type = 'MAIN'
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
    qualify row_number() over (partition by abn order by entity_name) = 1
)

select * from renamed

/*
  stg_abr_names — every name each ABN is known by (main, trading, other), for
  name-matching contracts that carry no ABN.

  stg_abr_entity keeps only the canonical name (one row per ABN) for enrichment;
  this keeps them all, so a contract that used a supplier's trading name can still
  resolve to its ABN. Used only by int_abr_name_lookup.

  Materialized as a table: ~25M rows, scanned once per build by the lookup.
*/
{{ config(materialized='table') }}

select
    {{ clean_string('abn') }}          as abn,
    {{ clean_string('entity_name') }}  as entity_name,
    {{ clean_string('name_type') }}    as name_type
from {{ source('abr_bronze', 'raw_abr_entity') }}
where abn is not null
  and entity_name is not null

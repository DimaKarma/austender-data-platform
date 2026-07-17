/*
  A name-matched ABN is a *suggestion*, so it must never pull a contract into a
  real (ABN-keyed) supplier entity — a possible false positive would then
  contaminate that supplier's numbers, the unrecoverable direction.

  This is the live guard the reviewer's suggested "check by resolved_abn" was
  reaching for. Checking resolved_abn directly would false-positive: a name-keyed
  fallback group legitimately holds rows with different resolved_abns (a
  suggestion next to a placeholder that share a normalized name). The real
  invariant is narrower and this asserts it: no abn_source = 'abr_name_match' row
  shares its supplier_entity_key with a stated, register-vouched (ABN-keyed) row.

  Fails with one row per offending name-matched supplier.
*/

with abn_keyed as (
    select distinct supplier_entity_key
    from {{ ref('dim_supplier') }}
    where abn_source = 'stated'
      and not supplier_abn_is_placeholder
      and abr_entity_name is not null
)

select
    d.supplier_key,
    d.supplier_name,
    d.supplier_entity_key
from {{ ref('dim_supplier') }} d
join abn_keyed k on d.supplier_entity_key = k.supplier_entity_key
where d.abn_source = 'abr_name_match'

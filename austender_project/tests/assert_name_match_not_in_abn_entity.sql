/*
  A name-matched ABN is a *suggestion*, so it must never pull a contract into a
  real (ABN-keyed) supplier entity — a possible false positive would then
  contaminate that supplier's numbers, the unrecoverable direction.

  Honest scope: this is a targeted TRIPWIRE, not a data-live guard. Under the
  current key it cannot fail — name-matched rows are keyed 'NAME:…' and
  register-vouched stated rows 'ABN:…', so they cannot share a supplier_entity_key
  by construction. It exists to catch a specific dangerous refactor: making
  entity_business_key group a name-matched (suggested) ABN under an ABN key. It is
  more precisely aimed than assert_supplier_rollup_never_merges_abns, but same
  category. The one genuinely consequential invariant — normalized_name unique in
  int_abr_name_lookup (a violation fans out the join and corrupts the dimension) —
  is asserted there.

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

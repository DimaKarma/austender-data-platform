/*
  The supplier rollup must never put two different real suppliers in one group.

  This guards the exact regression that forced an earlier design to be reverted:
  keying on the ABN merged 140 unrelated firms under the Department of Defence's
  ABN and labelled their contracts with a company that never won them. Merging is
  the unrecoverable direction — an analyst can split a group by hand, but cannot
  unmix a summed number — so it is worth a test of its own.

  The invariant: within one supplier_entity_key, at most one trustworthy ABN may
  appear. A group may hold several rows (spellings of a name, or a name-keyed
  fallback), but never two ABNs the register vouched for, because those are two
  registered entities.

  `unique` on supplier_key cannot see this: every merged row has its own key.

  Note: given the current key (an ABN group is 'ABN:'||supplier_abn), this query
  cannot fail — same key implies same ABN. It is kept as a structural tripwire
  that WOULD catch a future change to entity_business_key. The live invariant is
  asserted by assert_name_match_not_in_abn_entity instead.
*/

select
    supplier_entity_key,
    supplier_entity_name,
    count(distinct supplier_abn) as trustworthy_abns
from {{ ref('dim_supplier') }}
where
    abr_entity_name is not null
    and not supplier_abn_is_placeholder
group by supplier_entity_key, supplier_entity_name
having count(distinct supplier_abn) > 1

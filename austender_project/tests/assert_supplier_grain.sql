/*
  dim_supplier must hold one row per real supplier, not one per spelling of a
  supplier's name.

  The business key is the source's own identity rule — ABN when present, else
  name — so the dimension's row count must equal the number of distinct business
  keys in Silver, and no key may appear twice.

  This guards the regression it replaced: keying on (name, abn) produced 56,367
  rows for ~35,147 suppliers, because 6,942 ABNs appear under more than one
  spelling. `unique` on the surrogate key cannot catch that — the duplicates had
  genuinely distinct keys. Only comparing against Silver's own count can.
*/

with expected as (
    select count(distinct supplier_business_key) as n
    from {{ ref('slv_contracts') }}
),

actual as (
    select
        count(*)                     as n,
        count(distinct supplier_key) as n_keys
    from {{ ref('dim_supplier') }}
)

select
    expected.n    as expected_suppliers,
    actual.n      as dim_rows,
    actual.n_keys as distinct_dim_keys
from expected
cross join actual
where actual.n <> expected.n
   or actual.n_keys <> actual.n

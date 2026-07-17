/*
  The source encodes "this supplier has no ABN" two different ways: NULL, and the
  string '0'. Those 6,693 '0' rows are exactly the rows whose ABN is not 11
  digits — foreign suppliers (PANTA RHEI GMBH, PT. MITRA KARYA KREASI).

  Staging must collapse both to NULL so that "missing" has a single
  representation downstream and the same concept cannot be keyed two ways.
  Fails if the sentinel ever survives into Silver.
*/

select
    supplier_abn,
    count(*) as rows_affected
from {{ ref('slv_contracts') }}
where supplier_abn = '0'
group by supplier_abn

/*
  stg_abr_entity must hold exactly one row per ABN.

  Bronze now stores several names per ABN; stg_abr_entity filters to the canonical
  MAIN name. If a record ever produced more than one MAIN — or the filter broke —
  the dim_supplier enrichment join would fan out and inflate the dimension. This
  fails the build if any ABN appears twice.
*/

select abn, count(*) as n
from {{ ref('stg_abr_entity') }}
group by abn
having count(*) > 1

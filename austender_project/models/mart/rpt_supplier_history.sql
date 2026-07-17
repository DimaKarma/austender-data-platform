/*
  rpt_supplier_history — the supplier dimension's SCD2 history, for the mart.

  Surfaces the supplier_history snapshot with readable validity columns so an
  analyst can answer point-in-time questions ("what was this ABN's status on
  date D?") without touching the raw snapshot in gold. is_current marks the live
  version; valid_from/valid_to bound each version.

  The snapshot lives in gold (built by `dbt snapshot`); this view reads it, so it
  is empty until the snapshot has run at least once.
*/

with history as (
    select * from {{ ref('supplier_history') }}
)

select
    supplier_key,
    supplier_name,
    supplier_abn,
    abr_entity_name,
    abr_entity_type,
    abr_abn_status,
    supplier_abn_is_placeholder,
    dbt_valid_from                          as valid_from,
    dbt_valid_to                            as valid_to,
    (dbt_valid_to is null)                  as is_current
from history

/*
  dim_supplier — the "Supplier" dimension.
  Grain: one row per unique (supplier_name, supplier_abn) pair.

  The grain is the *stated* pair rather than the ABN, and that is deliberate: a
  contract's supplierabn cannot be trusted on its own. Keying on it merges
  unrelated firms, because agencies put their own ABN in the supplier field —
  see the README's data quality notes.

  Instead of guessing, the ABN is checked against the Australian Business
  Register (see stg_abr_entity). The abr_* columns say what the register knows
  about the stated ABN, and supplier_abn_is_placeholder marks the rows where it
  demonstrably is not this supplier's ABN. An analyst can then exclude or group
  those rows knowingly, instead of being handed silently merged numbers.
*/
{{ config(materialized='table') }}

with suppliers as (
    select distinct
        supplier_name,
        supplier_abn
    from {{ ref('slv_contracts') }}
    where supplier_name is not null
),

abr as (
    select abn, entity_name, entity_type_text, abn_status, is_government_entity
    from {{ ref('stg_abr_entity') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['s.supplier_name', 's.supplier_abn']) }} as supplier_key,
    s.supplier_name,
    s.supplier_abn,

    -- What the register says the stated ABN actually is. NULL when the supplier
    -- has no ABN ('UNKNOWN'), or when the ABN was never issued.
    a.entity_name                                   as abr_entity_name,
    a.entity_type_text                              as abr_entity_type,
    a.abn_status                                    as abr_abn_status,

    -- The stated ABN belongs to a government body that is not this supplier:
    -- an agency's own ABN standing in for a real one. This is the register's
    -- verdict, not a heuristic about how many names share an ABN.
    coalesce(
        a.is_government_entity
        and {{ normalize_name('s.supplier_name') }} <> {{ normalize_name('a.entity_name') }},
        false
    )                                               as supplier_abn_is_placeholder
from suppliers s
left join abr a
  on s.supplier_abn = a.abn

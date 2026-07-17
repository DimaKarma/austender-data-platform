/*
  dim_supplier — the "Supplier" dimension.
  Grain: one row per unique (supplier_name, supplier_abn) pair, as stated on the
  contract. Unchanged, so supplier_key and every fact referencing it keep working.

  The grain is the stated pair rather than the ABN because a contract's
  supplierabn cannot be trusted on its own — agencies put their own ABN in the
  supplier field. The abr_* columns say what the Australian Business Register
  knows about the stated ABN, and supplier_abn_is_placeholder marks the rows
  where it demonstrably is not this supplier's.

  supplier_entity_key then does what the grain cannot: it groups the rows that
  are one real supplier. Keying the dimension itself on the ABN was tried and
  reverted — it merged 140 unrelated firms under Defence's ABN. The difference
  now is that the register says which ABNs are safe to group on, so the rollup
  uses the ABN only where it is trustworthy and falls back to the name where it
  is not. Group on it for "how many suppliers" and "spend by supplier"; without
  it, Hays' 1,394 contracts stay split across 77 rows and never appear as one
  line in a report.
*/
{{ config(materialized='table') }}

with suppliers as (
    select distinct
        supplier_name,
        supplier_abn
    from {{ ref('slv_contracts') }}
    -- No null filter: Silver coalesces missing names to 'Unknown', so the
    -- dimension covers every contract the fact points at (no orphaned keys).
),

abr as (
    select abn, entity_name, entity_type_text, abn_status, is_government_entity
    from {{ ref('stg_abr_entity') }}
),

checked as (
    select
        s.supplier_name,
        s.supplier_abn,
        a.entity_name       as abr_entity_name,
        a.entity_type_text  as abr_entity_type,
        a.abn_status        as abr_abn_status,

        -- The stated ABN belongs to a government body that is not this supplier:
        -- an agency's own ABN standing in for a real one. The register's verdict,
        -- not a heuristic about how many names share an ABN.
        coalesce(
            a.is_government_entity
            and {{ normalize_name('s.supplier_name') }} <> {{ normalize_name('a.entity_name') }},
            false
        )                   as supplier_abn_is_placeholder
    from suppliers s
    left join abr a
      on s.supplier_abn = a.abn
),

keyed as (
    select
        *,
        -- Group on the ABN only where the register vouches for it. Everything
        -- else — no ABN, an ABN never issued, or a placeholder — falls back to
        -- the name. The fallback over-splits (two spellings with no ABN stay
        -- apart), which is the recoverable direction: an analyst can group rows,
        -- but a wrongly merged number cannot be unmixed.
        case
            when abr_entity_name is not null and not supplier_abn_is_placeholder
                then 'ABN:' || supplier_abn
            else 'NAME:' || {{ normalize_name('supplier_name') }}
        end as entity_business_key,

        -- The name to show for the group. Taken from the register when grouping
        -- on the ABN, from the contract otherwise — deliberately not coalesced
        -- across the two, or a placeholder row would be labelled with the
        -- agency's name it is standing in for.
        case
            when abr_entity_name is not null and not supplier_abn_is_placeholder
                then abr_entity_name
            else supplier_name
        end as entity_name_candidate
    from checked
),

entity_names as (
    -- One display name per group. min() only has to be deterministic: for an
    -- ABN group every candidate is the same registered name, and for a name
    -- group it picks one spelling stably across rebuilds.
    select
        entity_business_key,
        min(entity_name_candidate) as supplier_entity_name
    from keyed
    group by entity_business_key
)

select
    {{ dbt_utils.generate_surrogate_key(['k.supplier_name', 'k.supplier_abn']) }} as supplier_key,
    k.supplier_name,
    k.supplier_abn,

    k.abr_entity_name,
    k.abr_entity_type,
    k.abr_abn_status,
    k.supplier_abn_is_placeholder,

    {{ dbt_utils.generate_surrogate_key(['k.entity_business_key']) }}             as supplier_entity_key,
    e.supplier_entity_name
from keyed k
join entity_names e
  on k.entity_business_key = e.entity_business_key

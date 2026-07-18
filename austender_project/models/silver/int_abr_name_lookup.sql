/*
  int_abr_name_lookup — a safe name -> ABN map for the contracts that carry no
  ABN, built from the register.

  Discipline: a normalized supplier name maps to a register ABN only when it maps
  to *exactly one* ABN across the whole register. If two different companies share
  a normalized name, the match is ambiguous and dropped — a suggested ABN must
  never be a guess between candidates. Restricted to names our no-ABN contracts
  actually use, so it stays small and relevant.

  Matches against ALL of the register's names — main, trading and other (via
  stg_abr_names) — so a contract that used a supplier's trading name still
  resolves. A normalized name is still required to map to exactly one ABN across
  every name in the register; sharing a trading name makes it ambiguous and drops
  it, same discipline as before.

  The result is only ever surfaced as a *suggested* ABN, flagged
  abn_source = 'abr_name_match' in dim_supplier, never merged into a real
  supplier's entity or asserted as a stated ABN.
*/
{{ config(materialized='table') }}

with contract_names as (
    select distinct {{ normalize_name('supplier_name') }} as normalized_name
    from {{ ref('slv_contracts') }}
    where
        supplier_abn = 'UNKNOWN'
        and supplier_name <> 'Unknown'
),

register as (
    select distinct {{ normalize_name('entity_name') }} as normalized_name, abn
    from {{ ref('stg_abr_names') }}
    where entity_name is not null
),

matched as (
    select
        c.normalized_name,
        count(distinct r.abn) as n_abns,
        max(r.abn) as matched_abn
    from contract_names as c
    inner join register as r on c.normalized_name = r.normalized_name
    group by c.normalized_name
)

-- Unique matches only.
select
    normalized_name,
    matched_abn
from matched
where n_abns = 1

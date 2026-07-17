/*
  Fails if fct_contracts has drifted from slv_contracts.

  Why this exists: the fact is incremental, so a wrong incremental predicate
  leaves Gold silently behind Silver — rows never inserted, or amendments never
  applied. No built-in test can see that. `unique`/`not_null` check the fact
  against itself, and `relationships` checks it against the dimensions; all of
  them stay green while the fact quietly serves stale numbers.

  This compares the two layers row by row and returns one row per problem, so
  dbt fails the build and names what diverged.

  Note the layers are compared on business content only — surrogate keys and
  loaded_at are deliberately excluded, since those are Gold's own additions.
*/

with silver as (
    select
        contract_id, contract_value, duration_days, procurement_method,
        publish_date, contract_start_date, contract_end_date
    from {{ ref('slv_contracts') }}
),

gold as (
    select
        contract_id, contract_value, duration_days, procurement_method,
        publish_date, contract_start_date, contract_end_date
    from {{ ref('fct_contracts') }}
),

-- A contract exists in Silver but never made it into the fact.
missing_in_gold as (
    select s.contract_id, 'missing_in_gold' as issue
    from silver s
    left join gold g on s.contract_id = g.contract_id
    where g.contract_id is null
),

-- The fact carries a contract Silver no longer has.
orphaned_in_gold as (
    select g.contract_id, 'not_in_silver' as issue
    from gold g
    left join silver s on g.contract_id = s.contract_id
    where s.contract_id is null
),

-- The contract is in both, but the fact holds outdated values: exactly what a
-- merge that can only insert (never update) produces.
stale_in_gold as (
    select s.contract_id, 'stale_value_in_gold' as issue
    from silver s
    join gold g on s.contract_id = g.contract_id
    where s.contract_value      is distinct from g.contract_value
       or s.duration_days       is distinct from g.duration_days
       or s.procurement_method  is distinct from g.procurement_method
       or s.publish_date        is distinct from g.publish_date
       or s.contract_start_date is distinct from g.contract_start_date
       or s.contract_end_date   is distinct from g.contract_end_date
)

select * from missing_in_gold
union all
select * from orphaned_in_gold
union all
select * from stale_in_gold

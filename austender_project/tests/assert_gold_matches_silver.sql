/*
  Fails if fct_contracts has drifted from slv_contracts.

  Why this exists: the fact is incremental, so a wrong predicate or a merge that
  cannot update leaves Gold silently behind Silver. No built-in test sees that —
  `unique`/`not_null` check the fact against itself and `relationships` checks it
  against the dimensions, so all of them stay green while the fact serves stale
  numbers.

  The layers sit at different grains by design: Silver keeps every AusTender
  notice, Gold keeps one row per contract holding its latest amendment. So this
  re-derives the expected winner from Silver independently of the model and
  compares. Deriving it again here is deliberate duplication: it is what makes
  the test an outside check on the incremental merge rather than a restatement
  of it.

  Business content only — surrogate keys and loaded_at are Gold's own additions.
*/

with expected as (
    select
        {{ base_contract_id('contract_id') }} as contract_id,
        contract_value, duration_days, procurement_method,
        publish_date, contract_start_date, contract_end_date
    from {{ ref('slv_contracts') }}
    qualify row_number() over (
        partition by {{ base_contract_id('contract_id') }}
        order by {{ amendment_no('contract_id') }} desc, loaded_at desc
    ) = 1
),

actual as (
    select
        contract_id, contract_value, duration_days, procurement_method,
        publish_date, contract_start_date, contract_end_date
    from {{ ref('fct_contracts') }}
),

-- A contract exists in Silver but never made it into the fact.
missing_in_gold as (
    select e.contract_id, 'missing_in_gold' as issue
    from expected e
    left join actual a on e.contract_id = a.contract_id
    where a.contract_id is null
),

-- The fact carries a contract Silver no longer has.
orphaned_in_gold as (
    select a.contract_id, 'not_in_silver' as issue
    from actual a
    left join expected e on a.contract_id = e.contract_id
    where e.contract_id is null
),

-- Present in both, but the fact holds the wrong version: what a merge that can
-- only insert, or a watermark that skips amendments, produces.
stale_in_gold as (
    select e.contract_id, 'stale_value_in_gold' as issue
    from expected e
    join actual a on e.contract_id = a.contract_id
    where e.contract_value      is distinct from a.contract_value
       or e.duration_days       is distinct from a.duration_days
       or e.procurement_method  is distinct from a.procurement_method
       or e.publish_date        is distinct from a.publish_date
       or e.contract_start_date is distinct from a.contract_start_date
       or e.contract_end_date   is distinct from a.contract_end_date
)

select * from missing_in_gold
union all
select * from orphaned_in_gold
union all
select * from stale_in_gold

{#
  SCD2 history for the supplier dimension.

  What is tracked, and why this and not agency renames: the "renames" the backlog
  imagined for agencies turned out not to exist — 13 of 14 multi-name agency ABNs
  have *overlapping* date spans, i.e. they are distinct reporting units sharing an
  ABN concurrently (Centrelink, Human Services and Agriculture all ran under one
  ABN 2003-2011), not one entity renamed over time. SCD2 keyed on that ABN would
  fabricate a timeline. So agency name is not a slowly-changing attribute here.

  The genuine slowly-changing attributes are the ones sourced from the Australian
  Business Register, which is refreshed weekly upstream: an ABN's status flips
  ACT -> CAN when a supplier deregisters, and the registered entity name is
  updated. This snapshot records those changes against a stable dimension member
  (supplier_key = hash of name + ABN), so you can answer "when did this supplier's
  ABN get cancelled?" — history the rebuilt dimension would otherwise overwrite.

  strategy=check on the ABR columns: a new version is cut only when one of them
  actually changes, not on every run. Snapshots are stateful and survive
  --full-refresh by design.
#}
{% snapshot supplier_history %}
{{
    config(
        target_schema=('ci_gold' if target.name == 'ci' else 'gold'),
        unique_key='supplier_key',
        strategy='check',
        check_cols=['abr_entity_name', 'abr_entity_type', 'abr_abn_status',
                    'supplier_abn_is_placeholder'],
        invalidate_hard_deletes=True
    )
}}

    select
        supplier_key,
        supplier_name,
        supplier_abn,
        abr_entity_name,
        abr_entity_type,
        abr_abn_status,
        supplier_abn_is_placeholder
    from {{ ref('dim_supplier') }}

{% endsnapshot %}

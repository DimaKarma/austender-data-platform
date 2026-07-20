{% docs __overview__ %}

# AusTender Data Platform

A Snowflake + dbt medallion pipeline over real Australian federal contracts data
(241,164 notices, 1999–2011), enriched against the Australian Business Register.
This site is the generated model documentation and lineage graph; the source is at
[github.com/DimaKarma/austender-data-platform](https://github.com/DimaKarma/austender-data-platform).

## Layers

- **Bronze** (`source: bronze`) — the raw CSV loaded as-is, one row per notice.
- **Silver** (`stg_*`, `slv_*`, `int_*`) — typed, cleansed, deduplicated; the ABR
  is joined in as a second source to validate supplier ABNs.
- **Gold** (`fct_contracts`, `dim_*`) — a star schema. Amendment chains are
  collapsed to their latest version so amended contracts are not multi-counted.
- **Mart** (`rpt_*`) — reporting views; the only layer the analyst role can read.

## Delta ingestion (input → Bronze → fact)

The pipeline is incremental end to end, and the pieces reinforce each other:

- **On input**, the loader can pull only notices newer than Bronze's high-water
  mark (max `publishdate`) — a few hundred rows instead of the whole file — the
  way you would page a live API.
- **Into Bronze**, publishing is a MERGE on the notice key that refreshes
  `_loaded_at` *only* for rows that actually changed. Re-ingesting unchanged data
  writes nothing. A periodic full-snapshot MERGE also catches in-place corrections
  and source-side deletes.
- **Into the fact**, `fct_contracts` merges only the notices whose `loaded_at`
  advanced and re-collapses just those amendment chains. Because ingestion restamps
  only changed rows, a run over unchanged Bronze merges **0** rows rather than
  rebuilding the table — the incremental strategy does real work, not decoration.

Start with `fct_contracts` and follow the lineage graph (bottom-right) upstream to
Bronze, or open a `rpt_*` model to see the consumption layer.

{% enddocs %}

/*
  rpt_bi_dim_agency — agency dimension for the Power BI star.

  A thin mart view over the gold dimension so a Power BI model (which reads MART
  only, via the analyst role) can relate the rpt_contracts fact to conformed
  dimensions on surrogate keys. See powerbi/ for the model and measures.
*/

select
    agency_key,
    agency_name,
    agency_abn
from {{ ref('dim_agency') }}

/*
  rpt_bi_dim_category — procurement-category (UNSPSC) dimension for the Power BI
  star. Thin mart view over the gold dimension. See powerbi/.
*/

select
    category_key,
    category_name,
    category_unspsc
from {{ ref('dim_category') }}

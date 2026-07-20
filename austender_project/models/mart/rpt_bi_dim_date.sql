/*
  rpt_bi_dim_date — calendar dimension for the Power BI star. Thin mart view over
  the gold dimension so Power BI has a proper Date table to mark for time
  intelligence. Relate rpt_contracts[publish_date] to this on full_date.
*/

select
    date_key,
    full_date,
    year,
    quarter,
    month,
    month_name,
    day_of_month,
    day_of_week,
    day_name,
    is_weekend
from {{ ref('dim_date') }}

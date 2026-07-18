/*
  dim_date — the calendar dimension.

  The spine is a fixed literal range rather than one derived from the data:
  dbt_utils.date_spine needs its bounds at compile time, and a stable calendar
  is desirable anyway (the dimension should not shrink when the fact is
  filtered). The range therefore has to be wide enough to cover every date key
  the fact can produce.

  Source data spans 1986-02-01 (earliest contract_start_date) to 2037-03-08
  (latest contract_end_date), so 1985..2045 leaves margin on both sides.
  The relationships test on fct_contracts.publish_date_key in _gold__models.yml
  fails the build if the fact ever produces a key outside this range.
*/
{{ config(materialized='table') }}

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('1985-01-01' as date)",
        end_date="cast('2045-01-01' as date)"
    ) }}
)

select
    cast(to_char(date_day, 'YYYYMMDD') as integer) as date_key,
    date_day as full_date,
    year(date_day) as year,
    quarter(date_day) as quarter,
    month(date_day) as month,
    monthname(date_day) as month_name,
    day(date_day) as day_of_month,
    dayofweek(date_day) as day_of_week,
    dayname(date_day) as day_name,
    -- dayname is independent of the session WEEK_START parameter; dayofweek is
    -- not (its numbering shifts), so key the weekend flag off the name.
    (dayname(date_day) in ('Sat', 'Sun')) as is_weekend
from spine

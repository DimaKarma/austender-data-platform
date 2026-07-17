/*
  Nine contracts carry a value of exactly 1 — a placeholder, not a price. The
  source analysis flagged them and planned to correct them by hand from the
  SourceURL, but that link is a keyword search rather than the notice itself, so
  the real values are not recoverable from this extract.

  They pass Silver's `contract_value > 0` filter and are summed as if real.

  Warn rather than error, deliberately: the condition is known, measured and
  monitored, and hand-editing values would not survive a reload. This exists so
  the number is visible in every build and fails loudly only if it grows.
*/
{{ config(severity='warn') }}

select
    contract_id,
    source_notice_id,
    contract_value
from {{ ref('fct_contracts') }}
where contract_value = 1

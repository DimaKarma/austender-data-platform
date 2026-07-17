{#
  AusTender publishes an amendment as a *separate* contract notice whose id is
  the original id with an -A<n> suffix:

      413292      value 375,000     <- original notice
      413292-A1   value 500,000     <- first amendment
      413292-A2   value 240,000     <- second amendment, the contract as it stands

  Treating those as three contracts triple-counts the spend, so the Gold fact
  collapses each chain to its latest version. These macros are the single place
  the id is parsed.

  Verified against the full 241,164-row extract: every cnid matches either
  ^[0-9]+$ (228,699 rows) or ^[0-9]+-A[0-9]+$ (12,465 rows) — no other shape
  exists, so split_part on '-' is safe. Amendment numbers run 1..31.
#}

{% macro base_contract_id(column_name) -%}
    split_part({{ column_name }}, '-', 1)
{%- endmacro %}


{#
  Returns the amendment number, 0 for the original notice.
  Cast to INTEGER on purpose: ordering these as text would rank -A9 above -A10.
#}
{% macro amendment_no(column_name) -%}
    coalesce(try_cast(regexp_substr({{ column_name }}, '-A([0-9]+)$', 1, 1, 'e', 1) as integer), 0)
{%- endmacro %}

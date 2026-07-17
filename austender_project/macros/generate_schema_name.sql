{#
  By default dbt concatenates <target_schema>_<custom_schema> (e.g. silver_gold).
  A clean Medallion layout needs exactly BRONZE/SILVER/GOLD/MART, so the custom
  schema is normally used verbatim.

  The exception is the CI target. A PR build must not rebuild the SILVER/GOLD/MART
  that BI reads — otherwise a CI run mid-review hands an analyst a half-built
  table. So on target 'ci' every schema is prefixed CI_ (CI_SILVER, CI_GOLD,
  CI_MART), giving CI its own throwaway copy while it still reads the shared
  BRONZE sources. dev/prod is unchanged.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set base = custom_schema_name | trim if custom_schema_name is not none else target.schema -%}
    {%- if target.name == 'ci' -%}
        {{ 'ci_' ~ base }}
    {%- else -%}
        {{ base }}
    {%- endif -%}
{%- endmacro %}

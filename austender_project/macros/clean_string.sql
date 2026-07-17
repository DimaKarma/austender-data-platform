{#
  String normalization: TRIM + NULLIF on the empty string.
  Returns the cleaned value, or NULL when nothing is left.
#}
{% macro clean_string(column_name) -%}
    NULLIF(TRIM({{ column_name }}), '')
{%- endmacro %}

{#
  Case- and punctuation-insensitive form of a name, for comparing a contract's
  supplier name against the register's entity name.

  Deliberately does NOT strip legal suffixes (PTY LTD and friends). Doing so
  helps when matching a name to an unknown ABN, but here the comparison only has
  to answer "is this ABN's registered entity the same one the contract names?" —
  and the cases that matters for are government bodies, which carry no such
  suffix. Stripping would only add false equivalences.
#}
{% macro normalize_name(column_name) -%}
    trim(regexp_replace(upper({{ column_name }}), '[^A-Z0-9]+', ' '))
{%- endmacro %}

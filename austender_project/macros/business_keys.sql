{#
  The source identifies a supplier as "ABN if it has one, else the name". That is
  not a guess: it is exactly what the source's own supplierid column contains —
  the rule reproduces supplierid for 241,164 of 241,164 rows in the extract.

  Keying the dimension on (name, abn) instead treats every spelling of a name as
  a separate supplier. 6,942 ABNs appear under more than one spelling, which
  inflated dim_supplier from ~35,147 real suppliers to 56,367 rows — any "count
  of suppliers" was 60% too high.

  Expects an ABN that is already NULL when absent: stg_contracts collapses the
  '0' sentinel, so this macro never has to know about it.
#}
{% macro supplier_business_key(abn_column, name_column) -%}
    coalesce({{ abn_column }}, {{ name_column }})
{%- endmacro %}


{#
  An agency's ABN identifies its legal entity. Unlike suppliers, this is
  deliberately NOT the dimension's grain: one ABN covers both genuine reporting
  units (Questacon sits under its department's ABN) and historical renames
  (Centrelink -> Department of Human Services — five names on one ABN).

  Collapsing to the ABN would silently remove Questacon as something an analyst
  can slice by. dim_agency therefore keeps the reporting unit as its grain and
  exposes this as a rollup attribute, so the choice belongs to the query.
#}
{% macro agency_legal_entity_key(abn_column, name_column) -%}
    coalesce({{ abn_column }}, {{ name_column }})
{%- endmacro %}

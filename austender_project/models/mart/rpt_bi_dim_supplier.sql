/*
  rpt_bi_dim_supplier — supplier dimension for the Power BI star, at the grain of
  the real supplier ENTITY (supplier_entity_key), not the raw name spelling.

  dim_supplier holds one row per (name, ABN) spelling; the fact rpt_contracts
  relates on supplier_entity_key (spellings collapsed to one entity — see
  supplier_entity_key in gold), so this rolls the dimension up to that grain. Group
  by the entity key: supplier_entity_name is the entity's display name and is
  functionally determined by the key.
*/

select
    supplier_entity_key,
    any_value(supplier_entity_name) as supplier_entity_name,
    count(*) as name_spellings
from {{ ref('dim_supplier') }}
group by supplier_entity_key

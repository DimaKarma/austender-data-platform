// Power Query (M) source queries for each table in the model.
// Paste each into Power BI Desktop: Home > Transform data > New Source > Blank
// Query > Advanced Editor. Replace <account> with your Snowflake account host
// (e.g. abcdefg-xy12345.snowflakecomputing.com) — it is NOT committed here; the
// real value lives only in the gitignored ingestion/.env.
//
// Storage mode: Import (see README.md). Connect as a user holding austender_analyst,
// which can read MART only.

// ---- Fact: rpt_contracts ----
let
    Source = Snowflake.Databases("<account>.snowflakecomputing.com", "AUSTENDER_BI_WH"),
    DB     = Source{[Name = "AUSTENDER_DB"]}[Data],
    MART   = DB{[Name = "MART"]}[Data],
    Table  = MART{[Name = "RPT_CONTRACTS"]}[Data]
in
    Table

// ---- Dimension: rpt_bi_dim_supplier ----
let
    Source = Snowflake.Databases("<account>.snowflakecomputing.com", "AUSTENDER_BI_WH"),
    DB     = Source{[Name = "AUSTENDER_DB"]}[Data],
    MART   = DB{[Name = "MART"]}[Data],
    Table  = MART{[Name = "RPT_BI_DIM_SUPPLIER"]}[Data]
in
    Table

// ---- Dimension: rpt_bi_dim_agency ----
let
    Source = Snowflake.Databases("<account>.snowflakecomputing.com", "AUSTENDER_BI_WH"),
    DB     = Source{[Name = "AUSTENDER_DB"]}[Data],
    MART   = DB{[Name = "MART"]}[Data],
    Table  = MART{[Name = "RPT_BI_DIM_AGENCY"]}[Data]
in
    Table

// ---- Dimension: rpt_bi_dim_category ----
let
    Source = Snowflake.Databases("<account>.snowflakecomputing.com", "AUSTENDER_BI_WH"),
    DB     = Source{[Name = "AUSTENDER_DB"]}[Data],
    MART   = DB{[Name = "MART"]}[Data],
    Table  = MART{[Name = "RPT_BI_DIM_CATEGORY"]}[Data]
in
    Table

// ---- Dimension: rpt_bi_dim_date ----
let
    Source = Snowflake.Databases("<account>.snowflakecomputing.com", "AUSTENDER_BI_WH"),
    DB     = Source{[Name = "AUSTENDER_DB"]}[Data],
    MART   = DB{[Name = "MART"]}[Data],
    Table  = MART{[Name = "RPT_BI_DIM_DATE"]}[Data]
in
    Table

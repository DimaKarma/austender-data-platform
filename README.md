# AusTender Data Platform — Snowflake · dbt · Medallion · RBAC

An end-to-end analytics pipeline built on real data about Australian federal
contracts ([AusTender](https://www.tenders.gov.au/)). The project targets the
stack and requirements of the Medavie data-engineering role: **Snowflake, dbt,
Medallion Architecture, RBAC, CI/CD**.

## What this project demonstrates

- **Snowflake** — warehouse, database, schemas, file format, internal stage, `COPY INTO`.
- **RBAC** — functional roles (`de` / `analyst` / `ci`), a hierarchy under `SYSADMIN`,
  and least privilege (the analyst can only see the Gold layer).
- **Medallion Architecture** — three layers: **Bronze** (raw) → **Silver** (cleansed) → **Gold** (star schema).
- **dbt Core** — sources + freshness, staging/silver/gold models, surrogate keys,
  an **incremental** fact table, tests (`unique`, `not_null`, `relationships`), macros, `dbt_utils`.
- **CI/CD** — GitHub Actions: `dbt build` (run + test) on every PR.
- **ELT automation** — a Python loader instead of importing the CSV by hand.

## Architecture

```
                 ┌────────────────────────────────────────────────────────┐
 CSV (AusTender) │                     SNOWFLAKE                           │
       │         │                                                        │
       ▼         │   BRONZE                SILVER              GOLD        │
 load_to_bronze  │   raw_contract_data ─▶  stg_contracts ─▶   dim_supplier │
   (PUT + COPY)  │   (all STRING)          slv_contracts      dim_agency   │
                 │                         (types, dedup,     dim_category │
                 │                          COALESCE)         dim_date     │
                 │                                            fct_contracts│──▶ Power BI
                 └────────────────────────────────────────────────────────┘
        Python loader              dbt (staging→silver)     dbt (gold star schema)
```

The Gold model is a **star**: the `fct_contracts` fact (grain = one contract)
plus the `dim_supplier`, `dim_agency`, `dim_category` and `dim_date` dimensions,
joined through surrogate keys.

## Repository layout

```
Med-Pet/
├── bootstrap.py                     # from zero: infra → RBAC → bronze → dbt build
├── snowflake/
│   ├── 01_setup_infra_rbac.sql      # warehouse, db, schemas, roles, RBAC grants
│   └── 02_bronze_table_stage.sql    # bronze table, file format, stage
├── ingestion/
│   ├── load_to_bronze.py            # ELT: local CSV → PUT → COPY INTO bronze
│   └── .env.example                 # credentials template (the real .env is not committed)
├── austender_project/               # dbt project
│   ├── dbt_project.yml
│   ├── packages.yml                 # dbt_utils
│   ├── profiles.example.yml
│   ├── macros/                      # generate_schema_name, clean_string,
│   │                                #   contract_amendment (-A<n> parsing)
│   ├── tests/                       # assert_gold_matches_silver (drift guard)
│   └── models/
│       ├── staging/                 # _bronze__sources.yml, stg_contracts
│       ├── silver/                  # slv_contracts (+ tests)
│       └── gold/                    # dim_* , fct_contracts (+ tests)
├── .github/workflows/dbt_ci.yml     # CI: dbt build on PR
├── requirements.txt
└── .gitignore
```

## Getting started

### 0. Data
`AustralianFederalContracts.csv` (15 columns: `agencyname, value, suppliername,
description, publishdate, contractstart, contractend, procurementmethod, category,
agencyabn, supplierabn, categoryunspsc, cnid, supplierid, sourceurl`) sits in the
repo root. `cnid` is the natural key of a contract.

### 1. One command: `bootstrap.py`

```bash
pip install -r requirements.txt
cp ingestion/.env.example ingestion/.env    # fill in ACCOUNT + USER from the trial
python bootstrap.py
```

A single script stands the project up from scratch on a fresh trial: infra + RBAC
(substituting your username for `YOUR_USERNAME`), the bronze table and stage,
`profiles.yml` generation, the CSV load, and `dbt build`. It is idempotent — a
re-run is safe. If the credentials in `.env` are blank, the script stops and tells
you what is missing.

Flags: `--only-sql` (infrastructure only), `--skip-load`, `--skip-dbt`, `--file <path>`.

The Snowflake account itself is created by hand at
https://signup.snowflake.com (edition **Enterprise**); the signup is behind a
CAPTCHA and email confirmation, so it cannot be automated. The Account Identifier
comes from Snowsight → Admin → Accounts → copy button.

### 2. Manual path (when you want step-by-step control)

<details>
<summary>Expand</summary>

```sql
-- Worksheet, as ACCOUNTADMIN; replace YOUR_USERNAME (SELECT CURRENT_USER();)
snowflake/01_setup_infra_rbac.sql
-- as austender_de
snowflake/02_bronze_table_stage.sql
```
```bash
cd ingestion && python load_to_bronze.py --file ../AustralianFederalContracts.csv

cp austender_project/profiles.example.yml ~/.dbt/profiles.yml   # or use env_var
export SNOWFLAKE_ACCOUNT=... SNOWFLAKE_USER=... SNOWFLAKE_PASSWORD=...
cd austender_project && dbt deps && dbt build
dbt docs generate    # catalog + lineage
```
</details>

### 3. BI
Point Power BI / Tableau at the `AUSTENDER_DB.GOLD` schema (role
`austender_analyst`, read-only) and build dashboards on top of the star schema.

### Verifying RBAC (read this before concluding it is broken)

Snowflake enables **secondary roles** by default (`DEFAULT_SECONDARY_ROLES = ALL`).
If the account owner — who also holds `ACCOUNTADMIN` — connects with
`role=austender_analyst`, the session still carries every other role they own, so
it can read Silver and Bronze. That is the user's admin privileges leaking in, not
a hole in the grants. Turn secondary roles off to test the analyst honestly:

```sql
USE ROLE austender_analyst;
USE SECONDARY ROLES NONE;
SELECT COUNT(*) FROM gold.fct_contracts;    -- 241,164
SELECT COUNT(*) FROM silver.slv_contracts;  -- SQL compilation error: object does not exist
SELECT COUNT(*) FROM bronze.raw_contract_data;  -- SQL compilation error: object does not exist
```

Verified against the live account: Gold reads, Silver and Bronze are denied.
A real analyst user, granted only `austender_analyst`, is restricted with or
without this setting.

## Data quality notes

Figures below are measured against the full 241,164-row extract, not estimated.

| Field | Empty | Handling |
|---|---|---|
| `procurementmethod` | 62,961 (26.11%) | Silver → `'Unknown'` |
| `supplierabn` | 20,021 (8.30%) NULL | Silver → `'UNKNOWN'` |
| `agencyabn` | 1,219 (0.51%) | Silver → `'UNKNOWN'` |
| `categoryunspsc` | 92 (0.04%) | Silver → `'UNKNOWN'` |
| `description` | 56 (0.02%) — 48 NULL plus 8 whitespace-only | left NULL |

Rows without a contract value are filtered out in Silver, and duplicate notices
are collapsed to the most recent load.

**`supplierabn = '0'` is a sentinel, not a number — and is not yet normalized.**
A further 6,693 rows (2.78%) carry `'0'` instead of NULL. They are exactly the
rows whose ABN is not 11 digits, and they are foreign suppliers with no
Australian Business Number (`PANTA RHEI GMBH`, `PT. MITRA KARYA KREASI`). Only
suppliers carry it — `agencyabn` never does, since every agency is Australian.
Silver currently coalesces NULL to `'UNKNOWN'` but passes `'0'` through as if it
were a real ABN, so the same concept has two representations and 2,985
`dim_supplier` surrogate keys are built on the sentinel. Normalizing it would
change those keys, so it is left as a documented gap rather than a silent change.

**Amendments are separate notices, and they double-count.** AusTender publishes an
amendment as its own contract notice suffixed `-A<n>`: contract `413292` appears
three times, at 375,000 → 500,000 → 240,000. 12,465 rows (5.17%) are amendments.
Counting each notice as a contract overstated total spend by **$11.17B (5.8%)** —
$202.18B against the correct $191.01B. Silver keeps every notice at source grain;
the Gold fact collapses each chain to its latest amendment, so `fct_contracts`
carries one row per contract with `source_notice_id` and `amendment_no` recording
which version it is.

**`sourceurl` carries no information.** It is exactly
`https://www.tenders.gov.au/?event=public.advancedsearch.keyword&keyword=CN` +
`cnid` for all 241,164 rows — a search link derived from the id, not a link to the
notice, so it is not modelled downstream.

Two known caveats, deliberately not resolved: 9 contracts carry a placeholder
value of `1`, and agency names appear in punctuation variants
(`Department of Infrastructure, Transport` vs `... Transport`), which inflates
`dim_agency`.

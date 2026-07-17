"""
load_to_bronze.py
------------------------------------------------------------------
Automated AusTender ETL loader into the BRONZE layer in Snowflake.

Mirrors the production pattern:
    local CSV --PUT--> internal stage --COPY INTO--> bronze table

Notes:
  * Credentials come from the environment / .env — no passwords in code.
  * Idempotent: TRUNCATE + COPY, so a re-run does not duplicate rows.
  * Audit: the file name goes into _source_file, the timestamp comes from DEFAULT.
  * COPY returns load statistics (rows, errors) — logged.

Usage:
    pip install -r ../requirements.txt
    python load_to_bronze.py --file ../AustralianFederalContracts.csv
------------------------------------------------------------------
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

import snowflake.connector
from dotenv import load_dotenv

# Windows consoles default to a legacy code page and mangle non-ASCII output.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("bronze_loader")

REQUIRED_ENV = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD"]


def get_connection() -> snowflake.connector.SnowflakeConnection:
    """Build the connection from the environment. Passwords are never hardcoded."""
    load_dotenv()  # picks up ./.env when present
    missing = [v for v in REQUIRED_ENV if not os.getenv(v)]
    if missing:
        log.error("Missing environment variables: %s", ", ".join(missing))
        log.error("Copy .env.example to .env and fill in the credentials.")
        sys.exit(1)

    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.getenv("SNOWFLAKE_ROLE", "AUSTENDER_DE"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "AUSTENDER_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "AUSTENDER_DB"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "BRONZE"),
        client_session_keep_alive=True,
    )


def load_csv_to_bronze(csv_path: Path, truncate: bool = True) -> None:
    if not csv_path.exists():
        log.error("File not found: %s", csv_path)
        sys.exit(1)

    conn = get_connection()
    cur = conn.cursor()
    try:
        log.info("Connected. Role/warehouse: %s / %s",
                 *cur.execute("SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()").fetchone())

        # 1. Make sure the table/stage/format exist (idempotent DDL).
        #    In production 02_bronze_table_stage.sql already did this, but the
        #    loader repeats it so it can run standalone.
        cur.execute("""
            CREATE TABLE IF NOT EXISTS raw_contract_data (
                agencyname STRING, value STRING, suppliername STRING,
                description STRING, publishdate STRING, contractstart STRING,
                contractend STRING, procurementmethod STRING, category STRING,
                agencyabn STRING, supplierabn STRING, categoryunspsc STRING,
                cnid STRING, supplierid STRING, sourceurl STRING,
                _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
                _source_file STRING
            )
        """)
        cur.execute("""
            CREATE FILE FORMAT IF NOT EXISTS ff_csv_austender
                TYPE='CSV' SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='"'
                NULL_IF=('','NULL','null') EMPTY_FIELD_AS_NULL=TRUE ENCODING='UTF8'
        """)
        cur.execute("CREATE STAGE IF NOT EXISTS austender_stage FILE_FORMAT=ff_csv_austender")

        if truncate:
            log.info("TRUNCATE raw_contract_data (idempotent reload)")
            cur.execute("TRUNCATE TABLE raw_contract_data")

        # 2. PUT: upload the local file to the internal stage (auto-compressed).
        posix = csv_path.resolve().as_posix()
        log.info("PUT %s -> @austender_stage ...", csv_path.name)
        cur.execute(
            f"PUT 'file://{posix}' @austender_stage "
            "AUTO_COMPRESS=TRUE OVERWRITE=TRUE PARALLEL=4"
        )

        # 3. COPY INTO: stage -> bronze. Columns are listed explicitly and
        #    _source_file is filled from METADATA$FILENAME.
        log.info("COPY INTO raw_contract_data ...")
        cur.execute(f"""
            COPY INTO raw_contract_data (
                agencyname, value, suppliername, description, publishdate,
                contractstart, contractend, procurementmethod, category,
                agencyabn, supplierabn, categoryunspsc, cnid, supplierid,
                sourceurl, _source_file
            )
            FROM (
                SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,
                       METADATA$FILENAME
                FROM @austender_stage/{csv_path.name}.gz
            )
            FILE_FORMAT = (FORMAT_NAME = ff_csv_austender)
            ON_ERROR = 'CONTINUE'
        """)
        for row in cur.fetchall():
            log.info("COPY result: %s", row)

        cnt = cur.execute("SELECT COUNT(*) FROM raw_contract_data").fetchone()[0]
        log.info("Success: bronze.raw_contract_data now holds %s rows.", f"{cnt:,}")
    finally:
        cur.close()
        conn.close()
        log.info("Connection closed.")


def main() -> None:
    p = argparse.ArgumentParser(description="Load the AusTender CSV into the Bronze layer")
    p.add_argument("--file", default="../AustralianFederalContracts.csv",
                   help="Path to the CSV (default: ../AustralianFederalContracts.csv)")
    p.add_argument("--no-truncate", action="store_true",
                   help="Do not clear the table before loading (append mode)")
    args = p.parse_args()
    load_csv_to_bronze(Path(args.file), truncate=not args.no_truncate)


if __name__ == "__main__":
    main()

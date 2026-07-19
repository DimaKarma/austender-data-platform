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

from snowflake_auth import auth_kwargs

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

REQUIRED_ENV = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER"]

# The 15 source columns, in COPY order. cnid is the natural key of a notice.
BIZ_COLS = [
    "agencyname", "value", "suppliername", "description", "publishdate",
    "contractstart", "contractend", "procurementmethod", "category",
    "agencyabn", "supplierabn", "categoryunspsc", "cnid", "supplierid", "sourceurl",
]


def _snapshot_merge_sql(target: str, source: str) -> str:
    """Upsert half of the delta load: a MERGE on cnid.

    The file is the complete current state, so: insert new notices and update
    changed ones. Crucially, _loaded_at is refreshed ONLY for rows that actually
    changed (WHEN MATCHED carries a change predicate), so re-loading unchanged data
    is a true no-op and the incremental fact / SCD2 snapshot downstream process
    only the delta. current_timestamp() is statement-scoped, so every row touched
    by one load shares one watermark. Source-side removals are handled separately
    by _snapshot_delete_sql — Snowflake MERGE has no "not matched by source" clause.
    """
    change_cols = [c for c in BIZ_COLS if c != "cnid"]
    changed = " or ".join(f"t.{c} is distinct from s.{c}" for c in change_cols)
    set_clause = ", ".join(f"t.{c} = s.{c}" for c in BIZ_COLS)
    insert_cols = ", ".join(BIZ_COLS)
    insert_vals = ", ".join(f"s.{c}" for c in BIZ_COLS)
    return f"""
        MERGE INTO {target} AS t
        USING {source} AS s ON t.cnid = s.cnid
        WHEN MATCHED AND ({changed}) THEN UPDATE SET
            {set_clause},
            t._loaded_at = current_timestamp(),
            t._source_file = s._source_file
        WHEN NOT MATCHED THEN
            INSERT ({insert_cols}, _loaded_at, _source_file)
            VALUES ({insert_vals}, current_timestamp(), s._source_file)
    """


def _snapshot_delete_sql(target: str, source: str) -> str:
    """Delete half of the delta load: drop notices the snapshot no longer contains.

    Run in the same transaction as the MERGE so bronze is never briefly inconsistent.
    NOT EXISTS (not NOT IN) so a NULL cnid can never make the whole predicate NULL
    and wipe the table. This is why delta mode requires a COMPLETE snapshot: a
    partial file would delete every notice it omits.
    """
    return f"""
        DELETE FROM {target} AS t
        WHERE NOT EXISTS (SELECT 1 FROM {source} AS s WHERE s.cnid = t.cnid)
    """


def get_connection() -> snowflake.connector.SnowflakeConnection:
    """Build the connection from the environment. Credentials are never hardcoded."""
    load_dotenv()  # picks up ./.env when present
    missing = [v for v in REQUIRED_ENV if not os.getenv(v)]
    if not os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH") and not os.getenv("SNOWFLAKE_PASSWORD"):
        missing.append("SNOWFLAKE_PASSWORD or SNOWFLAKE_PRIVATE_KEY_PATH")
    if missing:
        log.error("Missing environment variables: %s", ", ".join(missing))
        log.error("Copy .env.example to .env and fill in the credentials.")
        sys.exit(1)

    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.getenv("SNOWFLAKE_ROLE", "AUSTENDER_DE"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "AUSTENDER_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "AUSTENDER_DB"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "BRONZE"),
        client_session_keep_alive=True,
        **auth_kwargs(),
    )


def load_csv_to_bronze(csv_path: Path, mode: str = "delta") -> None:
    """Load the AusTender snapshot into bronze.

    mode="delta" (default): the file is the complete current state, MERGEd on cnid
    so only genuinely new/changed/removed notices touch bronze — re-loading the same
    file is a no-op and downstream incrementals process only the delta. mode="full":
    the legacy TRUNCATE+INSERT replace, kept for a clean first load or a reset.
    """
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

        # 2. PUT: upload the local file to the internal stage (auto-compressed).
        posix = csv_path.resolve().as_posix()
        log.info("PUT %s -> @austender_stage ...", csv_path.name)
        cur.execute(
            f"PUT 'file://{posix}' @austender_stage "
            "AUTO_COMPRESS=TRUE OVERWRITE=TRUE PARALLEL=4"
        )

        # 3. COPY INTO a scratch table first, then swap.
        #
        #    Never TRUNCATE the live table before COPY: with ON_ERROR aborting a
        #    bad load (see below), a truncate-then-failed-copy would leave bronze
        #    EMPTY — the failure mode would destroy data instead of preserving it.
        #    So COPY into an empty clone; the live table only changes once COPY
        #    has fully succeeded.
        #
        #    ON_ERROR = 'ABORT_STATEMENT', not 'CONTINUE': Bronze must be a
        #    faithful copy of the source. CONTINUE would skip malformed rows
        #    silently, so schema drift would shrink the dataset with no signal.
        log.info("COPY INTO scratch table raw_contract_data_load ...")
        cur.execute("CREATE OR REPLACE TEMPORARY TABLE raw_contract_data_load "
                    "LIKE raw_contract_data")
        cur.execute(f"""
            COPY INTO raw_contract_data_load (
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
            ON_ERROR = 'ABORT_STATEMENT'
        """)
        # COPY result columns: file, status, rows_parsed, rows_loaded, ...
        for row in cur.fetchall():
            log.info("COPY result: %s", row)
            parsed, loaded = row[2], row[3]
            if parsed != loaded:
                # ABORT_STATEMENT should already have raised; belt and suspenders.
                log.error("COPY loaded %s of %s parsed rows — aborting.", loaded, parsed)
                sys.exit(1)

        # 4. Publish. Only reached because COPY succeeded.
        if mode == "delta":
            # Snapshot upsert + delete against the live table, but refresh
            # _loaded_at only for rows that actually changed (see the SQL builders).
            # Re-loading the same file writes nothing. Both statements run in one
            # transaction so bronze is never briefly inconsistent.
            log.info("Publishing (delta): MERGE + prune snapshot into raw_contract_data")
            cur.execute("BEGIN")
            cur.execute(_snapshot_merge_sql("raw_contract_data", "raw_contract_data_load"))
            # MERGE result set: (rows inserted, rows updated).
            merged = cur.fetchone()
            cur.execute(_snapshot_delete_sql("raw_contract_data", "raw_contract_data_load"))
            deleted = cur.fetchone()  # (rows deleted,)
            cur.execute("COMMIT")
            log.info("Delta result: inserted/updated=%s, deleted=%s", merged, deleted)
        else:
            log.info("Publishing (full): replace raw_contract_data with the loaded rows")
            cur.execute("BEGIN")
            cur.execute("TRUNCATE TABLE raw_contract_data")
            cur.execute("INSERT INTO raw_contract_data SELECT * FROM raw_contract_data_load")
            cur.execute("COMMIT")

        cnt = cur.execute("SELECT COUNT(*) FROM raw_contract_data").fetchone()[0]
        log.info("Success: bronze.raw_contract_data now holds %s rows.", f"{cnt:,}")
    except snowflake.connector.errors.ProgrammingError as e:
        # Almost always a COPY that aborted on a malformed row. The live table was
        # not touched (COPY targets a scratch table), so report and exit cleanly.
        log.error("Load failed, bronze left unchanged: %s", str(e).splitlines()[0])
        sys.exit(1)
    finally:
        cur.close()
        conn.close()
        log.info("Connection closed.")


def main() -> None:
    p = argparse.ArgumentParser(description="Load the AusTender CSV into the Bronze layer")
    p.add_argument("--file", default="../AustralianFederalContracts.csv",
                   help="Path to the CSV (default: ../AustralianFederalContracts.csv)")
    p.add_argument("--full-reload", action="store_true",
                   help="Replace the table (TRUNCATE+INSERT) instead of a delta MERGE. "
                        "Use for a clean first load or a reset; delta is the default.")
    args = p.parse_args()
    load_csv_to_bronze(Path(args.file), mode="full" if args.full_reload else "delta")


if __name__ == "__main__":
    main()

"""
load_abr_to_bronze.py
------------------------------------------------------------------
Loads the Australian Business Register (ABR) bulk extract into the BRONZE layer
as a second source, alongside the AusTender contracts.

Why this source exists: a contract's supplierabn cannot be trusted on its own.
Agencies routinely put their *own* ABN in the supplier field — ABN 68706814312
is the Department of Defence, and it appears under 140 different supplier names.
The register is the only authority that can tell a placeholder ABN from a real
vendor's, so it is loaded and joined rather than guessed at.

Pipeline: download (2 ZIPs, ~944 MB) -> stream the XML -> CSV -> PUT -> COPY INTO.

The XML is never extracted to disk: 12.5 GB across 20 files is streamed straight
out of the archives and cleared as it goes, so memory stays flat.

Source: https://data.gov.au/data/dataset/abn-bulk-extract
Licence: Creative Commons Attribution 3.0 Australia (CC-BY) — attribution is in
the README.

Usage:
    python load_abr_to_bronze.py                 # download, parse, load
    python load_abr_to_bronze.py --skip-download # reuse what is already on disk
    python load_abr_to_bronze.py --parse-only    # stop before Snowflake
------------------------------------------------------------------
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
import time
import urllib.request
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import snowflake.connector
from dotenv import load_dotenv

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("abr_loader")

HERE = Path(__file__).resolve().parent
WORK = HERE / "abr_data"
CSV_OUT = WORK / "abr_entities.csv"

BASE = ("https://data.gov.au/data/dataset/5bd7fcab-e315-42cb-8daf-50b7efc2027e"
        "/resource")
PARTS = {
    "abr_part1.zip": f"{BASE}/0ae4d427-6fa8-4d40-8e76-c6909b5a071b/download/public_split_1_10.zip",
    "abr_part2.zip": f"{BASE}/635fcb95-7864-4509-9fa7-a62a6e32b62d/download/public_split_11_20.zip",
}

COLUMNS = ["abn", "abn_status", "abn_status_from_date", "entity_type_ind",
           "entity_type_text", "entity_name", "state", "postcode"]

REQUIRED_ENV = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD"]


# --- download ---------------------------------------------------------

def download() -> None:
    WORK.mkdir(exist_ok=True)
    for name, url in PARTS.items():
        target = WORK / name
        if target.exists() and target.stat().st_size > 100_000_000:
            log.info("%s already present (%.0f MB), skipping", name,
                     target.stat().st_size / 1e6)
            continue
        log.info("downloading %s ...", name)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req) as r, target.open("wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        log.info("  %s: %.0f MB", name, target.stat().st_size / 1e6)


# --- parse ------------------------------------------------------------

def record_name(el) -> str:
    """The entity's registered name.

    A record carries either a NonIndividualName (companies) or an IndividualName
    (sole traders, who do bid for federal contracts). Prefer the main name
    (type="MN"); fall back to whatever name is present.
    """
    best = ""
    for n in el.iter("NonIndividualName"):
        text = (n.findtext("NonIndividualNameText") or "").strip()
        if not text:
            continue
        if n.get("type") == "MN":
            return text
        best = best or text
    for ind in el.iter("IndividualName"):
        full = " ".join(p for p in (ind.findtext("GivenName"),
                                    ind.findtext("FamilyName")) if p).strip()
        if full:
            if ind.get("type") == "LGL":
                return full
            best = best or full
    return best


def parse() -> int:
    zips = sorted(WORK.glob("abr_part*.zip"))
    if not zips:
        log.error("No ABR archives in %s — run without --skip-download first.", WORK)
        sys.exit(1)

    t0 = time.time()
    written = 0
    with CSV_OUT.open("w", encoding="utf-8", newline="") as out:
        w = csv.writer(out)
        w.writerow(COLUMNS)
        for zp in zips:
            z = zipfile.ZipFile(zp)
            for info in z.infolist():
                if not info.filename.lower().endswith(".xml"):
                    continue
                with z.open(info) as fh:
                    for _, el in ET.iterparse(fh, events=("end",)):
                        if el.tag != "ABR":
                            continue
                        abn_el = el.find("ABN")
                        if abn_el is None or not (abn_el.text or "").strip():
                            el.clear()
                            continue
                        w.writerow([
                            abn_el.text.strip(),
                            abn_el.get("status"),
                            abn_el.get("ABNStatusFromDate"),
                            el.findtext("EntityType/EntityTypeInd"),
                            el.findtext("EntityType/EntityTypeText"),
                            record_name(el),
                            el.findtext(".//AddressDetails/State"),
                            el.findtext(".//AddressDetails/Postcode"),
                        ])
                        written += 1
                        el.clear()
                log.info("  %s -> %s rows so far [%.0fs]", info.filename,
                         f"{written:,}", time.time() - t0)
    log.info("parsed %s ABR records in %.0fs -> %s (%.0f MB)", f"{written:,}",
             time.time() - t0, CSV_OUT.name, CSV_OUT.stat().st_size / 1e6)
    return written


# --- load -------------------------------------------------------------

def get_connection() -> snowflake.connector.SnowflakeConnection:
    load_dotenv(HERE / ".env")
    missing = [v for v in REQUIRED_ENV if not os.getenv(v)]
    if missing:
        log.error("Missing environment variables: %s", ", ".join(missing))
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


def load() -> None:
    conn = get_connection()
    cur = conn.cursor()
    try:
        log.info("Connected. Role/warehouse: %s / %s",
                 *cur.execute("SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()").fetchone())
        # Idempotent DDL, same as the contracts loader: everything STRING in Bronze.
        cur.execute("""
            CREATE TABLE IF NOT EXISTS raw_abr_entity (
                abn STRING, abn_status STRING, abn_status_from_date STRING,
                entity_type_ind STRING, entity_type_text STRING,
                entity_name STRING, state STRING, postcode STRING,
                _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
                _source_file STRING
            )
        """)
        # The file format normally comes from 02_bronze_table_stage.sql, but
        # recreate it here so this loader also works standalone — same reason the
        # contracts loader repeats its own DDL.
        cur.execute("""
            CREATE FILE FORMAT IF NOT EXISTS ff_csv_austender
                TYPE='CSV' SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='"'
                NULL_IF=('','NULL','null') EMPTY_FIELD_AS_NULL=TRUE ENCODING='UTF8'
        """)
        cur.execute("CREATE STAGE IF NOT EXISTS abr_stage FILE_FORMAT=ff_csv_austender")

        log.info("TRUNCATE raw_abr_entity (idempotent reload)")
        cur.execute("TRUNCATE TABLE raw_abr_entity")

        posix = CSV_OUT.resolve().as_posix()
        log.info("PUT %s -> @abr_stage ...", CSV_OUT.name)
        cur.execute(f"PUT 'file://{posix}' @abr_stage "
                    "AUTO_COMPRESS=TRUE OVERWRITE=TRUE PARALLEL=4")

        log.info("COPY INTO raw_abr_entity ...")
        cur.execute(f"""
            COPY INTO raw_abr_entity (
                abn, abn_status, abn_status_from_date, entity_type_ind,
                entity_type_text, entity_name, state, postcode, _source_file
            )
            FROM (
                SELECT $1,$2,$3,$4,$5,$6,$7,$8, METADATA$FILENAME
                FROM @abr_stage/{CSV_OUT.name}.gz
            )
            FILE_FORMAT = (FORMAT_NAME = ff_csv_austender)
            ON_ERROR = 'ABORT_STATEMENT'
        """)
        for row in cur.fetchall():
            log.info("COPY result: %s", row)
        n = cur.execute("SELECT COUNT(*) FROM raw_abr_entity").fetchone()[0]
        log.info("Success: bronze.raw_abr_entity now holds %s rows.", f"{n:,}")
    finally:
        cur.close()
        conn.close()
        log.info("Connection closed.")


def main() -> None:
    p = argparse.ArgumentParser(description="Load the ABR bulk extract into Bronze")
    p.add_argument("--skip-download", action="store_true",
                   help="Reuse the archives already in ingestion/abr_data")
    p.add_argument("--skip-parse", action="store_true",
                   help="Reuse the CSV already parsed")
    p.add_argument("--parse-only", action="store_true",
                   help="Stop before touching Snowflake")
    args = p.parse_args()

    if not args.skip_download:
        download()
    if not args.skip_parse:
        parse()
    if not args.parse_only:
        load()


if __name__ == "__main__":
    main()

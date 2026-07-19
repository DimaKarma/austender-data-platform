"""
bootstrap.py
------------------------------------------------------------------
Stands the project up from scratch on a fresh Snowflake trial: from an empty
account to a populated Gold layer in one command.

Steps:
    1. Preflight: read ingestion/.env, validate credentials, check the CSV.
    2. Infra + RBAC: run snowflake/01_setup_infra_rbac.sql as ACCOUNTADMIN,
       substituting the real username for the YOUR_USERNAME placeholder.
    3. Bronze: run snowflake/02_bronze_table_stage.sql as austender_de.
    4. dbt profile: generate austender_project/profiles.yml from .env.
    5. Load: ingestion/load_to_bronze.py (PUT + COPY INTO).
    6. Transform: dbt deps + dbt build (staging -> silver -> gold).

Idempotent: all DDL is IF NOT EXISTS and the bronze load is TRUNCATE + COPY,
so re-running is safe.

Usage:
    pip install -r requirements.txt
    python bootstrap.py                 # everything
    python bootstrap.py --skip-dbt      # stop after bronze
    python bootstrap.py --only-sql      # infrastructure only (steps 2-3)
------------------------------------------------------------------
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import snowflake.connector
from dotenv import dotenv_values

sys.path.insert(0, str(Path(__file__).resolve().parent / "ingestion"))
from snowflake_auth import auth_kwargs  # noqa: E402

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
log = logging.getLogger("bootstrap")

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / "ingestion" / ".env"
SQL_INFRA = ROOT / "snowflake" / "01_setup_infra_rbac.sql"
SQL_BRONZE = ROOT / "snowflake" / "02_bronze_table_stage.sql"
SQL_ABR_BRONZE = ROOT / "snowflake" / "03_abr_bronze.sql"
SQL_RESOURCE_MONITOR = ROOT / "snowflake" / "04_resource_monitor.sql"
DBT_DIR = ROOT / "austender_project"
LOADER = ROOT / "ingestion" / "load_to_bronze.py"
ABR_LOADER = ROOT / "ingestion" / "load_abr_to_bronze.py"
DEFAULT_CSV = ROOT / "AustralianFederalContracts.csv"

# Snowflake username: letters/digits/underscore. Validated before being
# substituted into GRANT, where it lands as a SQL identifier, not a parameter.
USERNAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_$]*$")


class BootstrapError(RuntimeError):
    """An expected failure — reported cleanly, without a traceback."""


# --- 1. Preflight -----------------------------------------------------

def load_env() -> dict[str, str]:
    if not ENV_FILE.exists():
        raise BootstrapError(
            f"Missing {ENV_FILE.relative_to(ROOT)}.\n"
            "Copy ingestion/.env.example to ingestion/.env and fill in the credentials."
        )

    env = {k: (v or "").strip() for k, v in dotenv_values(ENV_FILE).items()}

    # This check is the reason the script exists: it waits for credentials and
    # says exactly what is missing instead of failing somewhere deeper.
    blank = [k for k in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER") if not env.get(k)]
    if not env.get("SNOWFLAKE_PASSWORD") and not env.get("SNOWFLAKE_PRIVATE_KEY_PATH"):
        blank.append("SNOWFLAKE_PASSWORD or SNOWFLAKE_PRIVATE_KEY_PATH")
    if blank:
        raise BootstrapError(
            "Not set in ingestion/.env: " + ", ".join(blank) + "\n\n"
            "No Snowflake account yet? Do this first:\n"
            "  1. https://signup.snowflake.com — edition Enterprise\n"
            "  2. Follow the email link, set a username; the password is already in .env\n"
            "  3. SNOWFLAKE_ACCOUNT: Snowsight -> Admin -> Accounts -> copy button\n"
            "     (format ORG-ACCOUNT, e.g. ABCDEFG-XY12345)\n"
            "  4. SNOWFLAKE_USER: the username from step 2 (not the email)\n\n"
            "Then just run bootstrap.py again."
        )

    user = env["SNOWFLAKE_USER"]
    if not USERNAME_RE.match(user):
        raise BootstrapError(
            f"SNOWFLAKE_USER='{user}' does not look like a Snowflake username.\n"
            "Expected a login name (e.g. DECARMA), not an email address."
        )

    return env


def preflight(env: dict[str, str], csv_path: Path, need_csv: bool) -> None:
    for f in (SQL_INFRA, SQL_BRONZE, SQL_ABR_BRONZE, SQL_RESOURCE_MONITOR):
        if not f.exists():
            raise BootstrapError(f"SQL script not found: {f.relative_to(ROOT)}")
    if need_csv and not csv_path.exists():
        raise BootstrapError(
            f"CSV not found: {csv_path}\n"
            "Put AustralianFederalContracts.csv in the repo root, or pass --file."
        )
    log.info("Preflight ok. Account=%s User=%s", env["SNOWFLAKE_ACCOUNT"], env["SNOWFLAKE_USER"])


# --- 2-3. SQL ---------------------------------------------------------

def run_sql_file(env: dict[str, str], path: Path, role: str,
                 substitutions: dict[str, str] | None = None) -> None:
    """Run a whole .sql file. Role/warehouse come from the script's own
    USE ROLE statements, so only the starting role is set on the connection."""
    sql = path.read_text(encoding="utf-8")
    for placeholder, value in (substitutions or {}).items():
        if placeholder not in sql:
            log.warning("No %s placeholder in %s — skipping substitution",
                        placeholder, path.name)
        sql = sql.replace(placeholder, value)

    log.info("Running %s (role %s) ...", path.name, role)
    conn = snowflake.connector.connect(
        account=env["SNOWFLAKE_ACCOUNT"],
        user=env["SNOWFLAKE_USER"],
        role=role,
        client_session_keep_alive=True,
        **auth_kwargs(env),
    )
    try:
        # execute_string splits on ';' and honors USE ROLE between statements.
        for cur in conn.execute_string(sql, remove_comments=False):
            if not cur.description:
                continue
            for row in cur.fetchall():
                # Each script ends with SELECT '...' AS status — surface it.
                if len(row) == 1 and isinstance(row[0], str) and row[0].endswith("are ready"):
                    log.info("  %s", row[0])
    finally:
        conn.close()


def step_infra(env: dict[str, str]) -> None:
    # The script starts with USE ROLE ACCOUNTADMIN, but the .env role
    # (AUSTENDER_DE) does not exist yet — connect as ACCOUNTADMIN.
    run_sql_file(env, SQL_INFRA, role="ACCOUNTADMIN",
                 substitutions={"YOUR_USERNAME": env["SNOWFLAKE_USER"]})
    # Credit guard on the warehouses — also ACCOUNTADMIN.
    run_sql_file(env, SQL_RESOURCE_MONITOR, role="ACCOUNTADMIN")


def step_bronze(env: dict[str, str]) -> None:
    role = env.get("SNOWFLAKE_ROLE") or "AUSTENDER_DE"
    run_sql_file(env, SQL_BRONZE, role=role)
    # Created even when the ABR is not being loaded: stg_abr_entity depends on
    # the source unconditionally, so an empty table keeps dbt build working.
    run_sql_file(env, SQL_ABR_BRONZE, role=role)


# --- 4. dbt profile ---------------------------------------------------

PROFILE_TEMPLATE = """# Generated by bootstrap.py from ingestion/.env — do not edit by hand.
# Credentials are read from the environment, not stored here (profiles.yml is gitignored).
austender:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      {DEV_AUTH}
      role: AUSTENDER_DE
      warehouse: AUSTENDER_WH
      database: AUSTENDER_DB
      schema: silver
      threads: 4
      client_session_keep_alive: False
    ci:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_CI_USER', '') }}"
      private_key_path: "{{ env_var('SNOWFLAKE_CI_PRIVATE_KEY_PATH', '') }}"
      role: AUSTENDER_CI
      warehouse: AUSTENDER_CI_WH
      database: AUSTENDER_DB
      schema: silver
      threads: 4
"""


def step_dbt_profile(env: dict[str, str]) -> Path:
    """Write profiles.yml next to the dbt project rather than into ~/.dbt —
    the global file may serve other projects and must not be clobbered.
    The dev target uses key-pair when SNOWFLAKE_PRIVATE_KEY_PATH is set, else a
    password — matching what the loaders do."""
    if env.get("SNOWFLAKE_PRIVATE_KEY_PATH"):
        dev_auth = "private_key_path: \"{{ env_var('SNOWFLAKE_PRIVATE_KEY_PATH') }}\""
    else:
        dev_auth = "password: \"{{ env_var('SNOWFLAKE_PASSWORD') }}\""
    target = DBT_DIR / "profiles.yml"
    target.write_text(PROFILE_TEMPLATE.replace("{DEV_AUTH}", dev_auth), encoding="utf-8")
    log.info("Generated profiles.yml: %s", target.relative_to(ROOT))
    return target


# --- 5-6. Subprocesses ------------------------------------------------

def run_cmd(cmd: list[str], cwd: Path, env: dict[str, str]) -> None:
    log.info("$ %s", " ".join(cmd))
    proc_env = {**os.environ, **env}
    try:
        result = subprocess.run(cmd, cwd=cwd, env=proc_env)
    except OSError as e:
        raise BootstrapError(f"Could not run {cmd[0]!r}: {e}") from e
    if result.returncode != 0:
        raise BootstrapError(f"Command failed (exit {result.returncode}): {' '.join(cmd)}")


def step_load(env: dict[str, str], csv_path: Path) -> None:
    run_cmd([sys.executable, str(LOADER), "--file", str(csv_path)],
            cwd=LOADER.parent, env=env)


def step_load_abr(env: dict[str, str]) -> None:
    """Load the ABR reference data. Skipped by default: it downloads ~944MB and
    streams 12.5GB of XML, so a routine rebuild should not pay for it. The
    archives and parsed CSV are reused when already on disk."""
    run_cmd([sys.executable, str(ABR_LOADER)], cwd=ABR_LOADER.parent, env=env)


def dbt_command() -> list[str]:
    """Locate dbt for the interpreter running this script.

    A bare "dbt" is not enough: inside a venv the console script is not on PATH.
    Prefer the script next to this interpreter, so dbt comes from the same
    environment as the Snowflake connector. `python -m dbt.cli.main` is the last
    resort — it works, but runpy re-imports the module and prints a RuntimeWarning.
    """
    bin_dir = Path(sys.executable).parent
    for name in ("dbt.exe", "dbt"):
        candidate = bin_dir / name
        if candidate.exists():
            return [str(candidate)]
    on_path = shutil.which("dbt")
    if on_path:
        return [on_path]
    return [sys.executable, "-m", "dbt.cli.main"]


def step_dbt(env: dict[str, str]) -> None:
    dbt_env = {**env, "DBT_PROFILES_DIR": str(DBT_DIR)}
    dbt = dbt_command()
    run_cmd(dbt + ["deps"], cwd=DBT_DIR, env=dbt_env)
    run_cmd(dbt + ["build"], cwd=DBT_DIR, env=dbt_env)


# --- main -------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        description="Stand up the AusTender platform on a clean Snowflake trial")
    p.add_argument("--file", default=str(DEFAULT_CSV), help="Path to the AusTender CSV")
    p.add_argument("--only-sql", action="store_true",
                   help="Infrastructure + RBAC + bronze DDL only")
    p.add_argument("--skip-load", action="store_true", help="Skip loading the CSV into bronze")
    p.add_argument("--skip-dbt", action="store_true", help="Skip dbt deps/build")
    p.add_argument("--with-abr", action="store_true",
                   help="Also (re)load the ABR reference data — downloads ~944MB "
                        "and streams 12.5GB of XML; reuses whatever is on disk")
    args = p.parse_args()

    csv_path = Path(args.file)
    do_load = not (args.only_sql or args.skip_load)
    do_dbt = not (args.only_sql or args.skip_dbt)
    do_abr = args.with_abr and not args.only_sql

    try:
        env = load_env()
        preflight(env, csv_path, need_csv=do_load)

        step_infra(env)
        step_bronze(env)

        if do_dbt:
            step_dbt_profile(env)
        if do_load:
            step_load(env, csv_path)
        if do_abr:
            step_load_abr(env)
        if do_dbt:
            step_dbt(env)

    except BootstrapError as e:
        log.error("\n%s", e)
        sys.exit(1)
    # HttpError (unreachable account) does not subclass DatabaseError — catch the
    # base Error, otherwise a typo in .env produces a bare traceback.
    except snowflake.connector.errors.Error as e:
        log.error("Snowflake rejected the connection: %s", e)
        log.error("Check SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PASSWORD in "
                  "ingestion/.env.\nThe Account Identifier comes from Snowsight -> Admin -> "
                  "Accounts (format ORG-ACCOUNT), not the full URL.")
        sys.exit(1)

    # Report what actually ran — with --only-sql/--skip-dbt there is no Gold yet.
    if do_dbt:
        log.info("Done. The Gold layer is available in AUSTENDER_DB.GOLD "
                 "(role AUSTENDER_ANALYST has read access).")
    elif do_load:
        log.info("Done. Bronze is loaded. Gold was skipped — re-run without "
                 "--skip-dbt to build it.")
    else:
        log.info("Done. Infrastructure and RBAC are in place. No data loaded — "
                 "re-run without --only-sql/--skip-load to populate it.")


if __name__ == "__main__":
    main()

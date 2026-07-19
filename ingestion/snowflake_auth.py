"""
Shared Snowflake auth: prefer key-pair, fall back to password.

Automation (CI, deploy) already uses key-pair; this lets the local dev path do the
same when SNOWFLAKE_PRIVATE_KEY_PATH is set — so it keeps working if the account
ever enforces MFA on single-factor password logins. Password stays the default so
nothing breaks for an existing .env.
"""
from __future__ import annotations

import os


def auth_kwargs(env: dict | None = None) -> dict:
    """Return the connector auth kwargs from `env` (defaults to os.environ).

    Key-pair when SNOWFLAKE_PRIVATE_KEY_PATH points to an unencrypted PKCS#8 key;
    otherwise password from SNOWFLAKE_PASSWORD. `env` lets callers that read .env
    into a dict (e.g. bootstrap) share this logic.
    """
    env = os.environ if env is None else env
    key_path = (env.get("SNOWFLAKE_PRIVATE_KEY_PATH") or "").strip()
    if key_path:
        # Imported lazily so a password-only setup needs no cryptography extra.
        from cryptography.hazmat.primitives import serialization
        with open(key_path, "rb") as f:
            pk = serialization.load_pem_private_key(f.read(), password=None)
        der = pk.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        return {"private_key": der}
    return {"password": env["SNOWFLAKE_PASSWORD"]}

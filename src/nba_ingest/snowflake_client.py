"""Snowflake connection + file staging helpers.

Adapted from wow-ingest's snowflake_client.py. Supports two auth methods,
auto-detected by which env vars are set:

1. Password / Programmatic Access Token (PAT) — set SNOWFLAKE_PASSWORD.
   Simplest for local dev against an existing user. PATs are long-lived
   tokens you generate in Snowsight under your user; they auth identically
   to passwords from the connector's perspective.

2. Key-pair — set SNOWFLAKE_PRIVATE_KEY_PATH (local) or
   SNOWFLAKE_PRIVATE_KEY_BASE64 (CI). Industry standard for service users.
   Pass-phrase-protected keys: also set SNOWFLAKE_PRIVATE_KEY_PASSPHRASE.

If both are set, key-pair wins.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path
from typing import Any

import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization


def _maybe_load_private_key_der() -> bytes | None:
    """Return DER-encoded PKCS8 bytes if a key is configured, else None."""
    key_path = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH")
    key_b64 = os.environ.get("SNOWFLAKE_PRIVATE_KEY_BASE64")
    if not key_path and not key_b64:
        return None

    passphrase = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
    if key_path:
        pem_bytes = Path(os.path.expanduser(key_path)).read_bytes()
    else:
        pem_bytes = base64.b64decode(key_b64)  # type: ignore[arg-type]

    private_key = serialization.load_pem_private_key(
        pem_bytes,
        password=passphrase.encode() if passphrase else None,
        backend=default_backend(),
    )
    return private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def connect() -> snowflake.connector.SnowflakeConnection:
    """Open a Snowflake connection. Auth method auto-detected from env."""
    common = {
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "user": os.environ["SNOWFLAKE_USER"],
        "role": os.environ.get("SNOWFLAKE_ROLE", "DEVELOPER_ADMIN"),
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "NBA_INGEST_WH"),
        "database": os.environ.get("SNOWFLAKE_DATABASE", "ZK_NBA"),
    }

    private_key_der = _maybe_load_private_key_der()
    if private_key_der is not None:
        return snowflake.connector.connect(private_key=private_key_der, **common)

    password = os.environ.get("SNOWFLAKE_PASSWORD")
    if password:
        return snowflake.connector.connect(password=password, **common)

    raise RuntimeError(
        "No Snowflake auth method configured. Set SNOWFLAKE_PASSWORD (or PAT) "
        "for password auth, or SNOWFLAKE_PRIVATE_KEY_PATH / "
        "SNOWFLAKE_PRIVATE_KEY_BASE64 for key-pair auth."
    )


def put_and_merge(
    conn: snowflake.connector.SnowflakeConnection,
    local_file: Path,
    stage_path: str,
    merge_sql: str,
) -> dict[str, list[Any]]:
    """PUT a local NDJSON file to a stage, then run a MERGE that reads it.

    OVERWRITE = TRUE so a re-run with the same filename idempotently replaces
    the previous attempt rather than erroring.

    AUTO_COMPRESS = FALSE so the staged filename matches the local one exactly.
    The MERGE statement references the file by its full path (so we don't
    reprocess older files left in the stage).

    Args:
        conn: Open Snowflake connection.
        local_file: Path to the NDJSON file to upload.
        stage_path: Stage subpath, e.g. "@ZK_NBA.RAW.INGEST_STAGE/flat/games".
        merge_sql: MERGE statement that reads from `<stage_path>/<local_file.name>`.

    Returns:
        Dict with "put" and "merge" keys mapping to cursor result rows.
    """
    cursor = conn.cursor()
    try:
        posix = local_file.resolve().as_posix()
        cursor.execute(
            f"PUT 'file://{posix}' {stage_path} "
            f"OVERWRITE = TRUE AUTO_COMPRESS = FALSE"
        )
        put_rows = cursor.fetchall()

        cursor.execute(merge_sql)
        merge_rows = cursor.fetchall()

        return {"put": put_rows, "merge": merge_rows}
    finally:
        cursor.close()


def execute(
    conn: snowflake.connector.SnowflakeConnection,
    sql: str,
    params: tuple | None = None,
) -> list[Any]:
    """Execute a SQL statement and return all result rows.

    Args:
        conn: Open Snowflake connection.
        sql: SQL statement to execute.
        params: Optional bind parameters.

    Returns:
        List of result rows.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(sql, params)
        return cursor.fetchall()
    finally:
        cursor.close()

"""Use an isolated temporary database and generated test-only credentials."""
import os
import secrets
import tempfile
from pathlib import Path

_test_dir = tempfile.TemporaryDirectory(prefix="tripscript-tests-")
os.environ.update(
    APP_ENV="local",
    JWT_SECRET_KEY=secrets.token_urlsafe(48),
    DATABASE_URL="sqlite:///" + (Path(_test_dir.name) / "test.db").as_posix(),
    ENABLE_LEGACY_AUTH="false",
    ENABLE_ADMIN_API="false",
    ENABLE_API_DOCS="false",
    RECEIPT_LLM_KEEP_WARM_ENABLED="false",
)

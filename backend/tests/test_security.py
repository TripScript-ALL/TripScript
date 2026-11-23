from datetime import datetime, timedelta, timezone
import secrets

import pytest
from fastapi.testclient import TestClient
from jose import jwt
from pydantic import ValidationError

from app.core.config import Settings, settings
from app.core.security import create_access_token
from app.main import app

client = TestClient(app)


@pytest.mark.parametrize("method,path", [
    ("get", "/api/v1/users/test-user/cards"),
    ("get", "/api/v1/users/test-user/trips"),
    ("patch", "/api/v1/users/test-user"),
    ("delete", "/api/v1/users/test-user"),
    ("post", "/api/v1/media/upload"),
    ("post", "/api/v1/receipts/recognize"),
    ("post", "/api/v1/receipts/recognize/compare"),
    ("post", "/api/v1/receipts/recognize-text"),
])
def test_private_routes_reject_missing_auth(method, path):
    assert client.request(method, path).status_code == 401


def test_user_cannot_read_another_users_cards():
    headers = {"Authorization": "Bearer " + create_access_token("alice")}
    assert client.get("/api/v1/users/bob/cards", headers=headers).status_code == 403


def test_signed_owner_token_reaches_user_route():
    headers = {"Authorization": "Bearer " + create_access_token("nonexistent-user")}
    response = client.get("/api/v1/users/nonexistent-user/cards", headers=headers)
    assert response.status_code == 404
    assert response.json()["detail"] == "User not found"


def test_local_predictable_token_is_rejected():
    headers = {"Authorization": "Bearer local-token-alice"}
    assert client.get("/api/v1/users/alice/cards", headers=headers).status_code == 401


def test_expired_token_cannot_fall_back_to_stored_token(monkeypatch):
    from app.api.routes import v1
    token = jwt.encode({"sub": "alice", "exp": datetime.now(timezone.utc) - timedelta(minutes=1)},
                       settings.jwt_secret_key, algorithm=settings.jwt_algorithm)
    monkeypatch.setitem(v1.USERS, "alice", {"id": "alice", "accessToken": token})
    assert client.get("/api/v1/me", headers={"Authorization": "Bearer " + token}).status_code == 401


def test_legacy_login_disabled():
    assert client.get("/api/v1/users/lookup", params={"name": "Sample", "phoneNumber": "00000000000"}).status_code == 403
    assert client.post("/api/v1/users", json={"name": "Sample", "phoneNumber": "00000000000"}).status_code == 403


def test_legacy_login_can_be_used_only_when_enabled_locally(monkeypatch):
    monkeypatch.setattr(settings, "enable_legacy_auth", True)
    response = client.post("/api/v1/users", json={"name": "Local test", "phoneNumber": "00000000000"})
    assert response.status_code == 201
    user = response.json()
    response = client.get(f"/api/v1/users/{user['id']}/cards", headers={"Authorization": "Bearer " + user["accessToken"]})
    assert response.status_code == 200


def test_admin_and_api_docs_are_disabled_by_default():
    assert client.get("/api/v1/admin/summary").status_code == 404
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_admin_requires_explicit_token(monkeypatch):
    token = secrets.token_urlsafe(48)
    monkeypatch.setattr(settings, "enable_admin_api", True)
    monkeypatch.setattr(settings, "admin_api_token", token)
    assert client.get("/api/v1/admin/summary").status_code == 401
    assert client.get("/api/v1/admin/summary", headers={"X-Admin-Token": "change-me-admin-token"}).status_code == 401
    assert client.get("/api/v1/admin/summary", headers={"X-Admin-Token": token}).status_code == 200


def test_production_rejects_legacy_auth():
    with pytest.raises(ValidationError, match="only allowed"):
        Settings(_env_file=None, app_env="production", enable_legacy_auth=True)


def test_placeholder_keys_fail_closed():
    with pytest.raises(ValidationError, match="JWT_SECRET_KEY"):
        Settings(_env_file=None, jwt_secret_key="change-me")
    with pytest.raises(ValidationError, match="ADMIN_API_TOKEN"):
        Settings(_env_file=None, enable_admin_api=True, admin_api_token="change-me-admin-token")  # pragma: allowlist secret


def test_database_url_is_used():
    assert settings.sqlite_path.name == "test.db"
    assert settings.sqlite_path.exists()

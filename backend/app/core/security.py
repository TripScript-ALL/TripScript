"""App JWT helpers and Kakao access-token profile lookup."""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import HTTPException, Request, status
from jose import JWTError, jwt

from app.core.config import settings

KAKAO_USER_ME_URL = "https://kapi.kakao.com/v2/user/me"


def create_access_token(user_id: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": user_id, "exp": int(expire.timestamp())}
    return jwt.encode(
        payload,
        settings.jwt_secret_key,
        algorithm=settings.jwt_algorithm,
    )


def decode_access_token_subject(token: str) -> str:
    payload = jwt.decode(
        token,
        settings.jwt_secret_key,
        algorithms=[settings.jwt_algorithm],
    )
    sub = payload.get("sub")
    if not isinstance(sub, str) or not sub:
        raise ValueError("missing sub")
    return sub


def _normalize_korean_phone(phone: object) -> str:
    raw = str(phone or "").strip()
    if not raw:
        return ""
    digits = "".join(ch for ch in raw if ch.isdigit())
    if digits.startswith("82") and len(digits) >= 11:
        return "0" + digits[2:]
    return digits


async def fetch_kakao_profile(access_token: str) -> dict | None:
    """Return Kakao account profile fields from access token, or None."""
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(
                KAKAO_USER_ME_URL,
                headers={"Authorization": f"Bearer {access_token}"},
            )
        if response.status_code != 200:
            return None
        data = response.json()
        kakao_id = data.get("id")
        if kakao_id is None:
            return None
        account = data.get("kakao_account") or {}
        profile = account.get("profile") or {}
        name = str(account.get("name") or "").strip()
        nickname = str(profile.get("nickname") or "").strip()
        display_name = name or nickname or f"카카오{kakao_id}"
        return {
            "kakaoUserId": str(kakao_id),
            "name": display_name,
            "phoneNumber": _normalize_korean_phone(account.get("phone_number")),
        }
    except (httpx.HTTPError, ValueError, TypeError, KeyError):
        return None


async def jwt_user_path_guard(request: Request) -> None:
    """Authenticate private API calls and bind user-scoped paths to their JWT."""
    path = request.url.path
    match = re.match(r"^/api/v1/users/([^/]+)", path)
    if match and match.group(1) == "lookup":
        return  # The route itself enforces the local-only legacy switch.
    protected = bool(match) or path == "/api/v1/media/upload" or path.startswith("/api/v1/receipts/recognize")
    if not protected:
        return
    # The local administrator can upload media via the existing admin UI.
    if path == "/api/v1/media/upload" and settings.enable_admin_api:
        import secrets
        supplied = request.headers.get("x-admin-token", "")
        if supplied and secrets.compare_digest(supplied.encode(), settings.admin_api_token.encode()):
            return
    authorization = request.headers.get("Authorization", "")
    if not authorization.startswith("Bearer ") or not authorization[7:].strip():
        raise HTTPException(status_code=401, detail="Authorization bearer token required")
    try:
        subject = decode_access_token_subject(authorization[7:].strip())
    except (JWTError, ValueError):
        raise HTTPException(status_code=401, detail="Invalid or expired token") from None
    if match and subject != match.group(1):
        raise HTTPException(status_code=403, detail="Token user does not match resource")

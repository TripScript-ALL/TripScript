from __future__ import annotations

import asyncio
from copy import deepcopy
from datetime import datetime, timezone
import html
import json
import mimetypes
import secrets
from pathlib import Path
import re
import sqlite3
from threading import RLock
from urllib.error import HTTPError, URLError
from urllib.parse import quote_plus, unquote, urlparse
from urllib.request import Request, urlopen
from uuid import uuid4

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request as FastAPIRequest, Response, UploadFile, status
from fastapi.responses import FileResponse
from jose import JWTError

from app.core.config import settings
from app.core.security import create_access_token, decode_access_token_subject, fetch_kakao_profile, jwt_user_path_guard
from app.services.receipt_recognition import recognize_receipt_image, recognize_receipt_text

router = APIRouter(
    prefix="/api/v1",
    tags=["api"],
    dependencies=[Depends(jwt_user_path_guard)],
)

DB_PATH = settings.sqlite_path
MEDIA_ROOT = DB_PATH.parent / "media"
_DB_LOCK = RLock()

USERS: dict[str, dict] = {}
TRIPS_BY_USER: dict[str, list[dict]] = {}
CARD_PROFILES_BY_USER: dict[str, list[dict]] = {}


def _json_dumps(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _json_loads(raw: str | None, fallback: object) -> object:
    if not raw:
        return fallback
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return fallback


def _first_present(*values: object) -> object | None:
    for value in values:
        if value is not None:
            return value
    return None


def _db_connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    try:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    except sqlite3.OperationalError:
        return set()


def _table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone()
    return row is not None

EXCHANGE_RATE_AS_OF_LABEL = "2026.05.06"
KRW_PER_CURRENCY_UNIT = {
    "KRW": 1.0,
    "USD": 1471.20,
    "EUR": 1722.48,
    "JPY": 9.368,
    "CNY": 216.54,
    "GBP": 1994.51,
    "CHF": 1884.16,
    "SEK": 157.0,
    "NOK": 146.0,
    "DKK": 231.0,
    "ISK": 11.4,
    "PLN": 404.0,
    "CZK": 70.0,
    "HUF": 4.35,
}
CARD_BRAND_FEE_RATES = {
    "visa": ("VISA", 0.011),
    "mastercard": ("Mastercard", 0.010),
    "master": ("Mastercard", 0.010),
    "maestro": ("Maestro", 0.010),
    "amex": ("AMEX", 0.014),
    "americanexpress": ("AMEX", 0.014),
    "jcb": ("JCB", 0.000),
    "unionpay": ("UnionPay", 0.008),
    "up": ("UnionPay", 0.008),
}
CARD_ISSUER_FEE_RATES = {
    "신한": ("신한카드", 0.0018),
    "신한카드": ("신한카드", 0.0018),
    "kb": ("KB국민카드", 0.0025),
    "국민": ("KB국민카드", 0.0025),
    "국민카드": ("KB국민카드", 0.0025),
    "kb국민": ("KB국민카드", 0.0025),
    "kb국민카드": ("KB국민카드", 0.0025),
    "현대": ("현대카드", 0.0018),
    "현대카드": ("현대카드", 0.0018),
    "삼성": ("삼성카드", 0.0020),
    "삼성카드": ("삼성카드", 0.0020),
    "롯데": ("롯데카드", 0.0020),
    "롯데카드": ("롯데카드", 0.0020),
    "하나": ("하나카드", 0.0020),
    "하나카드": ("하나카드", 0.0020),
    "우리": ("우리카드", 0.0030),
    "우리카드": ("우리카드", 0.0030),
    "농협": ("NH농협카드", 0.0025),
    "nh농협": ("NH농협카드", 0.0025),
    "nh농협카드": ("NH농협카드", 0.0025),
    "bc": ("BC카드", 0.0035),
    "비씨": ("BC카드", 0.0035),
    "비씨카드": ("BC카드", 0.0035),
    "기업": ("IBK기업은행(BC)", 0.0035),
    "ibk": ("IBK기업은행(BC)", 0.0035),
    "기업은행": ("IBK기업은행(BC)", 0.0035),
    "sc제일": ("SC제일은행(BC)", 0.0035),
    "sc제일은행": ("SC제일은행(BC)", 0.0035),
    "대구": ("DGB대구은행(BC)", 0.0035),
    "대구은행": ("DGB대구은행(BC)", 0.0035),
    "부산": ("BNK부산은행(BC)", 0.0035),
    "부산은행": ("BNK부산은행(BC)", 0.0035),
    "경남": ("BNK경남은행(BC)", 0.0035),
    "경남은행": ("BNK경남은행(BC)", 0.0035),
    "트래블월렛": ("트래블월렛", 0.0),
    "travelwallet": ("트래블월렛", 0.0),
}
CARD_ISSUER_FEE_POLICIES = {
    "신한카드": {
        "credit": {"type": "rate", "rate": 0.0018},
        "check": {"type": "rate", "rate": 0.0020},
    },
    "KB국민카드": {
        "credit": {"type": "rate", "rate": 0.0025},
        "check": {"type": "rate", "rate": 0.0025},
        "check_by_brand": {"maestro": {"type": "fixed_usd", "fixed_usd": 0.5}},
    },
    "현대카드": {
        "credit": {"type": "rate", "rate": 0.0018},
        "check": {"type": "rate", "rate": 0.0018},
    },
    "삼성카드": {
        "credit": {"type": "rate", "rate": 0.0020},
        "check": {"type": "rate", "rate": 0.0020},
    },
    "롯데카드": {
        "credit": {"type": "rate", "rate": 0.0020},
        "check": {"type": "rate", "rate": 0.0020},
    },
    "하나카드": {
        "credit": {"type": "rate", "rate": 0.0020},
        "check": {"type": "fixed_usd", "fixed_usd": 0.5},
    },
    "우리카드": {
        "credit": {"type": "rate", "rate": 0.0030},
        "check": {"type": "fixed_usd", "fixed_usd": 0.5},
    },
    "NH농협카드": {
        "credit": {"type": "rate", "rate": 0.0025},
        "check": {"type": "fixed_usd", "fixed_usd": 0.5},
    },
    "BC카드": {
        "credit": {"type": "rate", "rate": 0.0035},
        "check": {"type": "rate", "rate": 0.0035},
        "note": "BC 처리 카드는 은행/상품별 0.0%~0.35% 범위입니다.",
    },
    "트래블월렛": {
        "credit": {"type": "none", "rate": 0.0},
        "check": {"type": "none", "rate": 0.0},
        "prepaid": {"type": "none", "rate": 0.0},
        "note": "핀테크 외화충전/선불형 카드로 일반 카드사 수수료 계산에서 제외합니다.",
    },
}
FINTECH_TRAVEL_PROVIDERS = {"트래블월렛"}
CARD_PRODUCT_CATALOG = [
    {
        "name": "트래블로그",
        "company": "하나카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "travel_check",
    },
    {
        "name": "SOL트래블",
        "company": "신한카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "travel_credit",
    },
    {
        "name": "KB국민 트래블러스",
        "company": "KB국민카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "travel_check",
    },
    {
        "name": "우리WON트래블",
        "company": "우리카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "travel_check",
    },
    {
        "name": "NH트래블리",
        "company": "NH농협카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "travel_check",
    },
    {
        "name": "나라사랑카드",
        "company": "KB국민카드",
        "brand": "JCB",
        "cardType": "check",
        "category": "check",
    },
    {
        "name": "Deep Dream",
        "company": "신한카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "Mr.Life",
        "company": "신한카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "K-패스 신한카드 체크",
        "company": "신한카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "check",
    },
    {
        "name": "KB국민 WE:SH",
        "company": "KB국민카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "톡톡D",
        "company": "KB국민카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "ZERO Edition3",
        "company": "현대카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "M BOOST",
        "company": "현대카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "taptap O",
        "company": "삼성카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "iD ON",
        "company": "삼성카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "MULTI Any",
        "company": "하나카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "트래블로그 체크",
        "company": "하나카드",
        "brand": "Mastercard",
        "cardType": "check",
        "category": "travel_check",
    },
    {
        "name": "LOCA LIKIT",
        "company": "롯데카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "LOCA 365",
        "company": "롯데카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "카드의정석 EVERY 1",
        "company": "우리카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "DA@카드의정석",
        "company": "우리카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "올바른 FLEX",
        "company": "NH농협카드",
        "brand": "VISA",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "zgm.휴가중",
        "company": "NH농협카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "BC 바로 클리어",
        "company": "BC카드",
        "brand": "Mastercard",
        "cardType": "credit",
        "category": "credit",
    },
    {
        "name": "참! 좋은 글로벌체크카드",
        "company": "IBK기업은행",
        "brand": "VISA",
        "cardType": "check",
        "category": "check",
    },
]

CARD_PRODUCT_FEE_OVERRIDES = {
    "트래블로그": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_foreign_wallet",
        "foreign_wallet_required": True,
        "source_note": "트래블/외화머니 계열 상품으로 해외결제 수수료 면제 후보. 상품 조건은 카드사 고지와 실제 보유 상품 기준 확인 필요.",
    },
    "트래블로그 체크": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_foreign_wallet",
        "foreign_wallet_required": True,
        "source_note": "트래블/외화머니 계열 상품으로 해외결제 수수료 면제 후보. 상품 조건은 카드사 고지와 실제 보유 상품 기준 확인 필요.",
    },
    "SOL트래블": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_cashback",
        "foreign_wallet_required": False,
        "source_note": "여행 특화 상품으로 해외결제 수수료 면제/우대 후보. 세부 조건은 상품설명서 기준 확인 필요.",
    },
    "KB국민 트래블러스": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_cashback",
        "foreign_wallet_required": False,
        "source_note": "여행 특화 체크 상품으로 해외결제 수수료 면제/우대 후보. 세부 조건은 상품설명서 기준 확인 필요.",
    },
    "우리WON트래블": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_cashback",
        "foreign_wallet_required": False,
        "source_note": "여행 특화 체크 상품으로 해외결제 수수료 면제/우대 후보. 세부 조건은 상품설명서 기준 확인 필요.",
    },
    "NH트래블리": {
        "network_fee_waived": True,
        "issuer_fee_waived": True,
        "waiver_type": "upfront_or_cashback",
        "foreign_wallet_required": False,
        "source_note": "여행 특화 체크 상품으로 해외결제 수수료 면제/우대 후보. 세부 조건은 상품설명서 기준 확인 필요.",
    },
    "참! 좋은 글로벌체크카드": {
        "network_fee_waived": False,
        "issuer_fee_waived": False,
        "override_issuer_fee_type": "rate",
        "override_issuer_fee_rate": 0.0018,
        "source_note": "IBK 글로벌 체크 계열은 일반 BC 대표값 대신 상품 고지 수수료 후보를 우선 적용합니다.",
    },
}

CARD_TYPE_LABELS = {
    "credit": "신용",
    "check": "체크",
}
CARD_CHECK_FIXED_FEE_USD_BY_ISSUER = {
    "우리카드": 0.5,
    "NH농협카드": 0.5,
    "하나카드": 0.5,
}
TRAVEL_PRODUCT_KEYWORDS = (
    "트래블로그",
    "트래블월렛",
    "sol트래블",
    "쏠트래블",
    "트래블러스",
    "위비트래블",
    "nh트래블리",
    "i-travel",
    "itravel",
)

CARD_ISSUER_SOURCE_URLS = {
    "신한카드": "https://www.shinhancard.com/pconts/html/helpdesk/totalService/MOBFM12552/MOBFM12552A/MOBFM12552R05.html",
    "현대카드": "https://www.hyundaicard.com/upload/card/T_AZX-20260320-1452-98_%EA%B0%80%EC%9D%B4%EB%93%9C%EB%B6%81_SSG%20ed2_V2_%EA%B3%B5%EC%8B%9C%EC%8B%A4%EC%9A%A9.pdf",
    "KB국민카드": "https://card.kbcard.com/SVC/DVIEW/HSDMCXPRIBMC0043?mainCC=e",
    "NH농협카드": "https://card.nonghyup.com/IpCc2021R.act?CD_WRS_SQNO=90010515",
}

CARD_BRAND_SOURCE_URL = "https://www.shinhancard.com/pconts/html/helpdesk/totalService/MOBFM12552/MOBFM12552H/MOBFM12552R10.html"

TRIP_ADMIN_FIELDS = (
    "name",
    "startDate",
    "endDate",
    "participants",
    "hostName",
    "inviteCode",
    "tileColor",
    "coverImagePath",
)


def _as_float(value: object, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).replace(",", "").replace("%", "").strip())
    except ValueError:
        return default


def _normalize_fee_key(value: object) -> str:
    return "".join(
        ch for ch in str(value or "").lower() if ch.isalnum() or "가" <= ch <= "힣"
    )


def _find_fee_rule(value: object, table: dict[str, tuple[str, float]]) -> tuple[str, float] | None:
    key = _normalize_fee_key(value)
    if not key:
        return None
    if key in table:
        return table[key]
    for table_key, rule in table.items():
        if table_key in key or key in table_key:
            return rule
    return None


def _normalize_card_type(value: object) -> str:
    raw = str(value or "credit").strip().lower()
    if raw in {"prepaid", "wallet", "foreign_wallet", "선불", "외화", "외화선불", "외화머니"}:
        return "prepaid"
    if raw in {"check", "debit", "체크", "체크카드"}:
        return "check"
    return "credit"


def _is_travel_fee_exception(card_name: object) -> bool:
    key = _normalize_fee_key(card_name)
    return any(keyword in key for keyword in TRAVEL_PRODUCT_KEYWORDS)


def _issuer_policy_for(
    issuer_label: str,
    card_type: str,
    brand: object = None,
) -> dict:
    policy = CARD_ISSUER_FEE_POLICIES.get(issuer_label)
    if not policy:
        rule = _find_fee_rule(issuer_label, CARD_ISSUER_FEE_RATES)
        rate = rule[1] if rule else 0.0
        return {"type": "rate", "rate": rate, "fixed_usd": None, "note": None}

    brand_key = _normalize_fee_key(brand)
    brand_policies = policy.get(f"{card_type}_by_brand")
    if isinstance(brand_policies, dict):
        for key, value in brand_policies.items():
            if key in brand_key or brand_key in key:
                return {
                    "type": str(value.get("type") or "rate"),
                    "rate": float(value.get("rate") or 0.0),
                    "fixed_usd": value.get("fixed_usd"),
                    "note": value.get("note") or policy.get("note"),
                }

    value = policy.get(card_type) or policy.get("credit") or {}
    return {
        "type": str(value.get("type") or "rate"),
        "rate": float(value.get("rate") or 0.0),
        "fixed_usd": value.get("fixed_usd"),
        "note": value.get("note") or policy.get("note"),
    }


def _fee_catalog_items(
    table: dict[str, tuple[str, float]],
    *,
    source_urls: dict[str, str] | None = None,
    default_source_url: str | None = None,
) -> list[dict]:
    by_label: dict[str, dict] = {}
    for alias, (label, rate) in table.items():
        item = by_label.setdefault(
            label,
            {
                "id": _normalize_fee_key(label),
                "label": label,
                "rate": rate,
                "aliases": [],
                "sourceUrl": (source_urls or {}).get(label, default_source_url),
            },
        )
        item["aliases"].append(alias)
    return sorted(by_label.values(), key=lambda item: item["label"])


def _fee_catalog_items_from_db(kind: str) -> list[dict]:
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT id, label, rate, aliases_json, source_url
                FROM card_fee_catalog
                WHERE kind = ?
                ORDER BY label
                """,
                (kind,),
            ).fetchall()
    except sqlite3.Error:
        return []
    return [
        {
            "id": str(item_id),
            "label": str(label),
            "rate": float(rate),
            "aliases": _json_loads(aliases_json, []),
            "sourceUrl": source_url,
        }
        for item_id, label, rate, aliases_json, source_url in rows
    ]


def _create_normalized_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            nickname TEXT NOT NULL DEFAULT '',
            phone_number TEXT NOT NULL,
            settlement_bank_name TEXT NOT NULL DEFAULT '',
            settlement_account_number TEXT NOT NULL DEFAULT '',
            settlement_account_holder TEXT NOT NULL DEFAULT '',
            access_token TEXT NOT NULL,
            kakao_user_id TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS trips (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL,
            host_name TEXT NOT NULL,
            host_user_id TEXT,
            invite_code TEXT NOT NULL,
            countries_json TEXT NOT NULL DEFAULT '[]',
            tile_color INTEGER,
            cover_image_path TEXT,
            FOREIGN KEY(host_user_id) REFERENCES users(id) ON DELETE SET NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS trip_participants (
            trip_id TEXT NOT NULL,
            user_id TEXT,
            name TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (trip_id, name),
            FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE SET NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_trips (
            user_id TEXT NOT NULL,
            trip_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (user_id, trip_id),
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS receipts (
            id TEXT PRIMARY KEY,
            trip_id TEXT NOT NULL,
            store_name TEXT NOT NULL,
            amount REAL NOT NULL,
            date TEXT NOT NULL,
            category TEXT NOT NULL,
            image_path TEXT,
            paid_by TEXT NOT NULL,
            currency_code TEXT NOT NULL,
            payment_method TEXT NOT NULL,
            card_type TEXT NOT NULL DEFAULT 'credit',
            card_issuer TEXT,
            bank_name TEXT,
            card_brand TEXT,
            card_last4 TEXT,
            card_brand_fee_rate REAL,
            card_issuer_fee_rate REAL,
            issuer_fee_type TEXT,
            issuer_fee_fixed_usd REAL,
            cash_exchange_fee_rate REAL,
            cash_krw_per_unit REAL,
            payment_correction_rate REAL,
            estimated_krw_amount REAL,
            actual_krw_amount REAL,
            local_to_usd_rate REAL,
            usd_amount REAL,
            usd_to_krw_rate REAL,
            base_krw_amount REAL,
            exchange_rate_source TEXT,
            rate_date_label TEXT,
            confidence REAL,
            warnings_json TEXT NOT NULL DEFAULT '[]',
            recognition_json TEXT,
            FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS receipt_items (
            id TEXT PRIMARY KEY,
            receipt_id TEXT NOT NULL,
            item_index INTEGER NOT NULL,
            name TEXT NOT NULL,
            translated_name TEXT,
            quantity REAL NOT NULL,
            unit_price REAL NOT NULL,
            line_total REAL NOT NULL,
            category TEXT,
            FOREIGN KEY(receipt_id) REFERENCES receipts(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS receipt_item_splits (
            receipt_item_id TEXT NOT NULL,
            person_name TEXT NOT NULL,
            quantity REAL NOT NULL,
            PRIMARY KEY (receipt_item_id, person_name),
            FOREIGN KEY(receipt_item_id) REFERENCES receipt_items(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_profiles (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            name TEXT NOT NULL,
            company TEXT NOT NULL,
            brand TEXT NOT NULL,
            card_type TEXT NOT NULL DEFAULT 'credit',
            last4 TEXT,
            issuer_fee_rate REAL,
            issuer_fee_type TEXT NOT NULL DEFAULT 'rate',
            issuer_fee_fixed_usd REAL,
            brand_fee_rate REAL,
            network_fee_waived INTEGER NOT NULL DEFAULT 0,
            issuer_fee_waived INTEGER NOT NULL DEFAULT 0,
            product_override_note TEXT,
            fee_research_status TEXT NOT NULL DEFAULT 'idle',
            fee_research_summary TEXT,
            fee_research_sources_json TEXT NOT NULL DEFAULT '[]',
            fee_research_checked_at TEXT,
            fee_research_error TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_fee_catalog (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            label TEXT NOT NULL,
            rate REAL NOT NULL,
            aliases_json TEXT NOT NULL,
            source_url TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_issuer_fee_policies (
            id TEXT PRIMARY KEY,
            issuer_label TEXT NOT NULL,
            card_type TEXT NOT NULL,
            brand_label TEXT,
            fee_type TEXT NOT NULL,
            fee_rate REAL NOT NULL DEFAULT 0,
            fixed_usd REAL,
            source_url TEXT,
            source_note TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_products (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            company TEXT NOT NULL,
            brand TEXT NOT NULL,
            card_type TEXT NOT NULL,
            category TEXT NOT NULL,
            is_available INTEGER NOT NULL DEFAULT 1,
            source_url TEXT,
            source_checked_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_product_fee_overrides (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL,
            transaction_type TEXT NOT NULL DEFAULT 'purchase',
            network_fee_waived INTEGER NOT NULL DEFAULT 0,
            issuer_fee_waived INTEGER NOT NULL DEFAULT 0,
            override_network_fee_rate REAL,
            override_issuer_fee_type TEXT,
            override_issuer_fee_rate REAL,
            override_issuer_fee_fixed_usd REAL,
            waiver_type TEXT,
            foreign_wallet_required INTEGER NOT NULL DEFAULT 0,
            source_note TEXT,
            FOREIGN KEY(product_id) REFERENCES card_products(id) ON DELETE CASCADE
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS exchange_rates (
            currency_code TEXT NOT NULL,
            rate_date TEXT NOT NULL,
            krw_per_unit REAL NOT NULL,
            as_of_label TEXT NOT NULL,
            source TEXT NOT NULL,
            PRIMARY KEY (currency_code, rate_date)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS media_files (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            original_name TEXT,
            content_type TEXT,
            storage_path TEXT NOT NULL,
            public_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS settlement_transfer_statuses (
            trip_id TEXT NOT NULL,
            mode TEXT NOT NULL,
            from_name TEXT NOT NULL,
            to_name TEXT NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0,
            updated_by_user_id TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (trip_id, mode, from_name, to_name),
            FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE,
            FOREIGN KEY(updated_by_user_id) REFERENCES users(id) ON DELETE SET NULL
        )
        """
    )


def _ensure_normalized_schema(conn: sqlite3.Connection) -> None:
    user_columns = _table_columns(conn, "users")
    if "nickname" not in user_columns:
        conn.execute("ALTER TABLE users ADD COLUMN nickname TEXT NOT NULL DEFAULT ''")
    if "kakao_user_id" not in user_columns:
        conn.execute("ALTER TABLE users ADD COLUMN kakao_user_id TEXT")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_kakao_user_id "
        "ON users(kakao_user_id) WHERE kakao_user_id IS NOT NULL"
    )

    trip_columns = _table_columns(conn, "trips")
    if "host_user_id" not in trip_columns:
        conn.execute("ALTER TABLE trips ADD COLUMN host_user_id TEXT")
    if "countries_json" not in trip_columns:
        conn.execute("ALTER TABLE trips ADD COLUMN countries_json TEXT NOT NULL DEFAULT '[]'")

    participant_columns = _table_columns(conn, "trip_participants")
    if "user_id" not in participant_columns:
        conn.execute("ALTER TABLE trip_participants ADD COLUMN user_id TEXT")

    user_columns = _table_columns(conn, "users")
    user_additions = {
        "settlement_bank_name": "TEXT NOT NULL DEFAULT ''",
        "settlement_account_number": "TEXT NOT NULL DEFAULT ''",
        "settlement_account_holder": "TEXT NOT NULL DEFAULT ''",
    }
    for column, definition in user_additions.items():
        if column not in user_columns:
            conn.execute(f"ALTER TABLE users ADD COLUMN {column} {definition}")

    receipt_columns = _table_columns(conn, "receipts")
    if "cash_krw_per_unit" not in receipt_columns:
        conn.execute("ALTER TABLE receipts ADD COLUMN cash_krw_per_unit REAL")
    receipt_additions = {
        "card_type": "TEXT NOT NULL DEFAULT 'credit'",
        "issuer_fee_type": "TEXT",
        "issuer_fee_fixed_usd": "REAL",
        "confidence": "REAL",
        "warnings_json": "TEXT NOT NULL DEFAULT '[]'",
        "recognition_json": "TEXT",
    }
    for column, definition in receipt_additions.items():
        if column not in receipt_columns:
            conn.execute(f"ALTER TABLE receipts ADD COLUMN {column} {definition}")
    receipt_item_columns = _table_columns(conn, "receipt_items")
    if "translated_name" not in receipt_item_columns:
        conn.execute("ALTER TABLE receipt_items ADD COLUMN translated_name TEXT")
    card_columns = _table_columns(conn, "card_profiles")
    card_additions = {
        "card_type": "TEXT NOT NULL DEFAULT 'credit'",
        "issuer_fee_type": "TEXT NOT NULL DEFAULT 'rate'",
        "issuer_fee_fixed_usd": "REAL",
        "network_fee_waived": "INTEGER NOT NULL DEFAULT 0",
        "issuer_fee_waived": "INTEGER NOT NULL DEFAULT 0",
        "product_override_note": "TEXT",
        "fee_research_status": "TEXT NOT NULL DEFAULT 'idle'",
        "fee_research_summary": "TEXT",
        "fee_research_sources_json": "TEXT NOT NULL DEFAULT '[]'",
        "fee_research_checked_at": "TEXT",
        "fee_research_error": "TEXT",
    }
    for column, definition in card_additions.items():
        if column not in card_columns:
            conn.execute(f"ALTER TABLE card_profiles ADD COLUMN {column} {definition}")

    for statement in (
        "CREATE INDEX IF NOT EXISTS idx_user_trips_user_id ON user_trips(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_user_trips_trip_id ON user_trips(trip_id)",
        "CREATE INDEX IF NOT EXISTS idx_trip_participants_trip_id ON trip_participants(trip_id)",
        "CREATE INDEX IF NOT EXISTS idx_trip_participants_user_id ON trip_participants(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_trips_host_user_id ON trips(host_user_id)",
        "CREATE INDEX IF NOT EXISTS idx_receipts_trip_id ON receipts(trip_id)",
        "CREATE INDEX IF NOT EXISTS idx_receipts_trip_date ON receipts(trip_id, date)",
        "CREATE INDEX IF NOT EXISTS idx_receipts_paid_by ON receipts(paid_by)",
        "CREATE INDEX IF NOT EXISTS idx_receipt_items_receipt_id ON receipt_items(receipt_id)",
        "CREATE INDEX IF NOT EXISTS idx_receipt_items_receipt_order ON receipt_items(receipt_id, item_index)",
        "CREATE INDEX IF NOT EXISTS idx_receipt_item_splits_person_name ON receipt_item_splits(person_name)",
        "CREATE INDEX IF NOT EXISTS idx_card_profiles_user_id ON card_profiles(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_card_profiles_research_status ON card_profiles(fee_research_status)",
        "CREATE INDEX IF NOT EXISTS idx_card_issuer_fee_policies_lookup ON card_issuer_fee_policies(issuer_label, card_type, brand_label)",
        "CREATE INDEX IF NOT EXISTS idx_card_products_lookup ON card_products(company, card_type, name)",
        "CREATE INDEX IF NOT EXISTS idx_card_product_fee_overrides_product_id ON card_product_fee_overrides(product_id)",
        "CREATE INDEX IF NOT EXISTS idx_media_files_kind ON media_files(kind)",
        "CREATE INDEX IF NOT EXISTS idx_media_files_created_at ON media_files(created_at)",
        "CREATE INDEX IF NOT EXISTS idx_settlement_transfer_statuses_trip_id ON settlement_transfer_statuses(trip_id)",
    ):
        conn.execute(statement)


def _read_legacy_state(conn: sqlite3.Connection) -> dict | None:
    has_legacy = any(
        "payload" in _table_columns(conn, table)
        for table in ("users", "user_trips", "card_profiles")
    )
    if not has_legacy:
        return None

    state = {"users": {}, "trips_by_user": {}, "cards_by_user": {}}
    if "payload" in _table_columns(conn, "users"):
        for user_id, payload in conn.execute("SELECT id, payload FROM users"):
            state["users"][user_id] = _json_loads(payload, {})
    if "payload" in _table_columns(conn, "user_trips"):
        for user_id, payload in conn.execute("SELECT user_id, payload FROM user_trips"):
            state["trips_by_user"][user_id] = _json_loads(payload, [])
    if "payload" in _table_columns(conn, "card_profiles"):
        for user_id, payload in conn.execute("SELECT user_id, payload FROM card_profiles"):
            state["cards_by_user"][user_id] = _json_loads(payload, [])
    return state


def _seed_reference_tables(conn: sqlite3.Connection) -> None:
    conn.execute("DELETE FROM card_fee_catalog")
    conn.execute("DELETE FROM card_product_fee_overrides")
    conn.execute("DELETE FROM card_products")
    conn.execute("DELETE FROM card_issuer_fee_policies")
    for kind, table, sources, default_source in (
        ("issuer", CARD_ISSUER_FEE_RATES, CARD_ISSUER_SOURCE_URLS, None),
        ("brand", CARD_BRAND_FEE_RATES, {}, CARD_BRAND_SOURCE_URL),
    ):
        for item in _fee_catalog_items(
            table,
            source_urls=sources,
            default_source_url=default_source,
        ):
            conn.execute(
                """
                INSERT INTO card_fee_catalog
                    (id, kind, label, rate, aliases_json, source_url)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    f"{kind}:{item['id']}",
                    kind,
                    item["label"],
                    item["rate"],
                    _json_dumps(item["aliases"]),
                    item.get("sourceUrl"),
                ),
            )

    for issuer_label, policy in CARD_ISSUER_FEE_POLICIES.items():
        source_url = CARD_ISSUER_SOURCE_URLS.get(issuer_label)
        source_note = policy.get("note") if isinstance(policy, dict) else None
        for card_type in ("credit", "check"):
            value = policy.get(card_type) if isinstance(policy, dict) else None
            if not isinstance(value, dict):
                continue
            conn.execute(
                """
                INSERT INTO card_issuer_fee_policies (
                    id, issuer_label, card_type, brand_label, fee_type,
                    fee_rate, fixed_usd, source_url, source_note
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    f"{_normalize_fee_key(issuer_label)}:{card_type}",
                    issuer_label,
                    card_type,
                    None,
                    str(value.get("type") or "rate"),
                    float(value.get("rate") or 0.0),
                    value.get("fixed_usd"),
                    source_url,
                    value.get("note") or source_note,
                ),
            )
        for policy_key, value_by_brand in policy.items():
            if not str(policy_key).endswith("_by_brand") or not isinstance(value_by_brand, dict):
                continue
            card_type = str(policy_key).replace("_by_brand", "")
            for brand_label, value in value_by_brand.items():
                if not isinstance(value, dict):
                    continue
                conn.execute(
                    """
                    INSERT INTO card_issuer_fee_policies (
                        id, issuer_label, card_type, brand_label, fee_type,
                        fee_rate, fixed_usd, source_url, source_note
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        f"{_normalize_fee_key(issuer_label)}:{card_type}:{_normalize_fee_key(brand_label)}",
                        issuer_label,
                        card_type,
                        str(brand_label),
                        str(value.get("type") or "rate"),
                        float(value.get("rate") or 0.0),
                        value.get("fixed_usd"),
                        source_url,
                        value.get("note") or source_note,
                    ),
                )

    for product in CARD_PRODUCT_CATALOG:
        product_id = f"product:{_normalize_fee_key(product.get('company'))}:{_normalize_fee_key(product.get('name'))}:{_normalize_card_type(product.get('cardType'))}"
        conn.execute(
            """
            INSERT INTO card_products (
                id, name, company, brand, card_type, category,
                is_available, source_url, source_checked_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                product_id,
                str(product.get("name") or ""),
                str(product.get("company") or ""),
                str(product.get("brand") or ""),
                _normalize_card_type(product.get("cardType")),
                str(product.get("category") or "credit"),
                1 if product.get("isAvailable", True) else 0,
                product.get("sourceUrl"),
                product.get("sourceCheckedAt"),
            ),
        )
        override = CARD_PRODUCT_FEE_OVERRIDES.get(str(product.get("name") or ""))
        if override:
            conn.execute(
                """
                INSERT INTO card_product_fee_overrides (
                    id, product_id, transaction_type, network_fee_waived,
                    issuer_fee_waived, override_network_fee_rate,
                    override_issuer_fee_type, override_issuer_fee_rate,
                    override_issuer_fee_fixed_usd, waiver_type,
                    foreign_wallet_required, source_note
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    f"override:{product_id}:purchase",
                    product_id,
                    "purchase",
                    1 if override.get("network_fee_waived") else 0,
                    1 if override.get("issuer_fee_waived") else 0,
                    override.get("override_network_fee_rate"),
                    override.get("override_issuer_fee_type"),
                    override.get("override_issuer_fee_rate"),
                    override.get("override_issuer_fee_fixed_usd"),
                    override.get("waiver_type"),
                    1 if override.get("foreign_wallet_required") else 0,
                    override.get("source_note"),
                ),
            )

    static_rate_date = EXCHANGE_RATE_AS_OF_LABEL.replace(".", "-")
    for code, rate in KRW_PER_CURRENCY_UNIT.items():
        conn.execute(
            """
            INSERT INTO exchange_rates
                (currency_code, rate_date, krw_per_unit, as_of_label, source)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(currency_code, rate_date) DO UPDATE SET
                krw_per_unit = excluded.krw_per_unit,
                as_of_label = excluded.as_of_label,
                source = excluded.source
            """,
            (code, static_rate_date, rate, EXCHANGE_RATE_AS_OF_LABEL, "temporary_static"),
        )


def _init_db() -> None:
    with _DB_LOCK, _db_connect() as conn:
        legacy_state = _read_legacy_state(conn)
        if legacy_state is not None:
            for table in (
                "receipt_item_splits",
                "receipt_items",
                "receipts",
                "card_profiles",
                "user_trips",
                "trip_participants",
                "settlement_transfer_statuses",
                "trips",
                "card_fee_catalog",
                "card_issuer_fee_policies",
                "card_product_fee_overrides",
                "card_products",
                "exchange_rates",
                "users",
            ):
                conn.execute(f"DROP TABLE IF EXISTS {table}")
        elif _table_exists(conn, "exchange_rates") and "rate_date" not in _table_columns(
            conn,
            "exchange_rates",
        ):
            conn.execute("DROP TABLE IF EXISTS exchange_rates")
        _create_normalized_schema(conn)
        _ensure_normalized_schema(conn)
        _seed_reference_tables(conn)
        if legacy_state is not None:
            _write_state_to_db(conn, legacy_state)


def _write_user_row(conn: sqlite3.Connection, user: dict) -> None:
    user_id = str(user["id"])
    kakao_raw = user.get("kakaoUserId") if "kakaoUserId" in user else user.get("kakao_user_id")
    kakao_val = None
    if kakao_raw is not None:
        stripped = str(kakao_raw).strip()
        kakao_val = stripped or None
    conn.execute(
        """
        INSERT INTO users (
            id, name, nickname, phone_number,
            settlement_bank_name, settlement_account_number, settlement_account_holder,
            access_token, kakao_user_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            nickname = excluded.nickname,
            phone_number = excluded.phone_number,
            settlement_bank_name = excluded.settlement_bank_name,
            settlement_account_number = excluded.settlement_account_number,
            settlement_account_holder = excluded.settlement_account_holder,
            access_token = excluded.access_token,
            kakao_user_id = excluded.kakao_user_id
        """,
        (
            user_id,
            str(user.get("name") or ""),
            str(user.get("nickname") or ""),
            _normalize_phone(str(user.get("phoneNumber") or user.get("phone_number") or "")),
            str(user.get("settlementBankName") or user.get("settlement_bank_name") or ""),
            str(
                user.get("settlementAccountNumber")
                or user.get("settlement_account_number")
                or ""
            ),
            str(
                user.get("settlementAccountHolder")
                or user.get("settlement_account_holder")
                or ""
            ),
            str(user.get("accessToken") or f"local-token-{user_id}"),
            kakao_val,
        ),
    )


def _user_display_name(user: dict | None) -> str:
    if not user:
        return ""
    nickname = str(user.get("nickname") or "").strip()
    return nickname or str(user.get("name") or "").strip()


def _user_name_aliases(user: dict | None) -> set[str]:
    aliases: set[str] = set()
    if not user:
        return aliases
    for value in (user.get("name"), user.get("nickname"), _user_display_name(user)):
        text = str(value or "").strip()
        if text:
            aliases.add(text)
    return aliases


def _dedupe_names(names: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for name in names:
        text = str(name or "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        out.append(text)
    return out


def _find_user_by_participant_name(name: str) -> dict | None:
    text = str(name or "").strip()
    if not text:
        return None
    for user in USERS.values():
        if text in _user_name_aliases(user):
            return user
    return None


def _participant_display_name(name: object, user_id: object | None = None) -> str:
    if user_id:
        user = USERS.get(str(user_id))
        if user:
            display = _user_display_name(user)
            if display:
                return display
    user = _find_user_by_participant_name(str(name or ""))
    if user:
        display = _user_display_name(user)
        if display:
            return display
    return str(name or "").strip()


def _write_trip_row(conn: sqlite3.Connection, trip: dict) -> None:
    trip_id = str(trip["id"])
    cover_image_path = _valid_media_reference(
        trip.get("coverImagePath") or trip.get("cover_image_path")
    )
    host_user = USERS.get(str(trip.get("hostUserId") or trip.get("host_user_id") or ""))
    if host_user is None:
        host_user = _find_user_by_participant_name(
            str(trip.get("hostName") or trip.get("host_name") or "")
        )
    host_user_id = str(host_user.get("id")) if host_user else None
    host_name = _user_display_name(host_user) if host_user else str(
        trip.get("hostName") or trip.get("host_name") or ""
    )
    conn.execute(
        """
        INSERT INTO trips (
            id, name, start_date, end_date, host_name, host_user_id, invite_code,
            countries_json, tile_color, cover_image_path
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            host_name = excluded.host_name,
            host_user_id = excluded.host_user_id,
            invite_code = excluded.invite_code,
            countries_json = excluded.countries_json,
            tile_color = excluded.tile_color,
            cover_image_path = excluded.cover_image_path
        """,
        (
            trip_id,
            str(trip.get("name") or ""),
            str(trip.get("startDate") or trip.get("start_date") or ""),
            str(trip.get("endDate") or trip.get("end_date") or ""),
            host_name,
            host_user_id,
            str(trip.get("inviteCode") or trip.get("invite_code") or _new_invite_code()),
            _json_dumps(trip.get("countries") or []),
            trip.get("tileColor") if trip.get("tileColor") is not None else trip.get("tile_color"),
            cover_image_path,
        ),
    )
    conn.execute("DELETE FROM trip_participants WHERE trip_id = ?", (trip_id,))
    participants = _dedupe_names([
        _participant_display_name(name)
        for name in list(trip.get("participants") or [])
    ])
    if host_name:
        participants = _dedupe_names([host_name, *participants])
    for position, name in enumerate(participants):
        participant_user = _find_user_by_participant_name(name)
        conn.execute(
            """
            INSERT INTO trip_participants (trip_id, user_id, name, position)
            VALUES (?, ?, ?, ?)
            """,
            (
                trip_id,
                str(participant_user.get("id")) if participant_user else None,
                str(name),
                position,
            ),
        )
    _write_receipts_for_trip(conn, trip_id, list(trip.get("receipts") or []))


def _write_receipts_for_trip(
    conn: sqlite3.Connection,
    trip_id: str,
    receipts: list[dict],
) -> None:
    conn.execute("DELETE FROM receipts WHERE trip_id = ?", (trip_id,))
    for receipt in receipts:
        r = _estimate_receipt_payment(receipt)
        receipt_id = str(r.get("id") or uuid4())
        r["id"] = receipt_id
        conn.execute(
            """
            INSERT INTO receipts (
                id, trip_id, store_name, amount, date, category, image_path,
                paid_by, currency_code, payment_method, card_type, card_issuer, bank_name,
                card_brand, card_last4, card_brand_fee_rate, card_issuer_fee_rate,
                issuer_fee_type, issuer_fee_fixed_usd,
                cash_exchange_fee_rate, cash_krw_per_unit, payment_correction_rate,
                estimated_krw_amount, actual_krw_amount, local_to_usd_rate,
                usd_amount, usd_to_krw_rate, base_krw_amount,
                exchange_rate_source, rate_date_label, confidence,
                warnings_json, recognition_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                receipt_id,
                trip_id,
                str(r.get("storeName") or r.get("store_name") or ""),
                _as_float(r.get("amount")),
                str(r.get("date") or ""),
                str(r.get("category") or "기타"),
                r.get("imagePath") or r.get("image_path"),
                str(r.get("paidBy") or r.get("paid_by") or ""),
                str(r.get("currencyCode") or r.get("currency_code") or "KRW"),
                str(r.get("paymentMethod") or r.get("payment_method") or "card"),
                _normalize_card_type(r.get("cardType") or r.get("card_type")),
                r.get("cardIssuer") or r.get("card_issuer"),
                r.get("bankName") or r.get("bank_name"),
                r.get("cardBrand") or r.get("card_brand"),
                r.get("cardLast4") or r.get("card_last4"),
                _first_present(r.get("cardBrandFeeRate"), r.get("card_brand_fee_rate")),
                _first_present(r.get("cardIssuerFeeRate"), r.get("card_issuer_fee_rate")),
                _first_present(r.get("issuerFeeType"), r.get("issuer_fee_type")),
                _first_present(r.get("issuerFeeFixedUsd"), r.get("issuer_fee_fixed_usd")),
                _first_present(r.get("cashExchangeFeeRate"), r.get("cash_exchange_fee_rate")),
                _first_present(r.get("cashKrwPerUnit"), r.get("cash_krw_per_unit")),
                _first_present(r.get("paymentCorrectionRate"), r.get("payment_correction_rate")),
                _first_present(r.get("estimatedKrwAmount"), r.get("estimated_krw_amount")),
                _first_present(r.get("actualKrwAmount"), r.get("actual_krw_amount")),
                _first_present(r.get("localToUsdRate"), r.get("local_to_usd_rate")),
                _first_present(r.get("usdAmount"), r.get("usd_amount")),
                _first_present(r.get("usdToKrwRate"), r.get("usd_to_krw_rate")),
                _first_present(r.get("baseKrwAmount"), r.get("base_krw_amount")),
                r.get("exchangeRateSource") or r.get("exchange_rate_source"),
                r.get("rateDateLabel") or r.get("rate_date_label"),
                _first_present(r.get("confidence"), r.get("recognitionConfidence")),
                _json_dumps(list(r.get("warnings") or [])),
                _json_dumps(r.get("recognition") or {}),
            ),
        )
        for item_index, item in enumerate(list(r.get("items") or [])):
            item_id = str(item.get("id") or f"{receipt_id}:{item_index}")
            conn.execute(
                """
                INSERT INTO receipt_items (
                    id, receipt_id, item_index, name, translated_name, quantity,
                    unit_price, line_total, category
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item_id,
                    receipt_id,
                    item_index,
                    str(item.get("name") or item.get("itemName") or ""),
                    item.get("translatedName")
                    or item.get("translated_name")
                    or item.get("koreanName")
                    or item.get("korean_name"),
                    _as_float(item.get("quantity")),
                    _as_float(item.get("unitPrice") or item.get("unit_price")),
                    _as_float(item.get("lineTotal") or item.get("line_total")),
                    item.get("category"),
                ),
            )
            split_map = item.get("quantityByPerson") or item.get("quantity_by_person") or {}
            if isinstance(split_map, dict):
                for person_name, qty in split_map.items():
                    conn.execute(
                        """
                        INSERT INTO receipt_item_splits (
                            receipt_item_id, person_name, quantity
                        )
                        VALUES (?, ?, ?)
                        """,
                        (item_id, str(person_name), _as_float(qty)),
                    )


def _write_cards_for_user(
    conn: sqlite3.Connection,
    user_id: str,
    cards: list[dict],
) -> None:
    conn.execute("DELETE FROM card_profiles WHERE user_id = ?", (user_id,))
    for card in cards:
        card_id = str(card.get("id") or uuid4())
        conn.execute(
            """
            INSERT INTO card_profiles (
                id, user_id, name, company, brand, card_type, last4,
                issuer_fee_rate, issuer_fee_type, issuer_fee_fixed_usd,
                brand_fee_rate, network_fee_waived, issuer_fee_waived,
                product_override_note, fee_research_status,
                fee_research_summary, fee_research_sources_json,
                fee_research_checked_at, fee_research_error
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                card_id,
                user_id,
                str(card.get("name") or ""),
                str(card.get("company") or ""),
                str(card.get("brand") or ""),
                _normalize_card_type(card.get("cardType") or card.get("card_type")),
                card.get("last4"),
                _first_present(card.get("issuerFeeRate"), card.get("issuer_fee_rate")),
                card.get("issuerFeeType") or card.get("issuer_fee_type") or "rate",
                _first_present(card.get("issuerFeeFixedUsd"), card.get("issuer_fee_fixed_usd")),
                _first_present(card.get("brandFeeRate"), card.get("brand_fee_rate")),
                1 if card.get("networkFeeWaived") or card.get("network_fee_waived") else 0,
                1 if card.get("issuerFeeWaived") or card.get("issuer_fee_waived") else 0,
                card.get("productOverrideNote") or card.get("product_override_note"),
                str(card.get("feeResearchStatus") or card.get("fee_research_status") or "idle"),
                card.get("feeResearchSummary") or card.get("fee_research_summary"),
                _json_dumps(card.get("feeResearchSources") or card.get("fee_research_sources") or []),
                card.get("feeResearchCheckedAt") or card.get("fee_research_checked_at"),
                card.get("feeResearchError") or card.get("fee_research_error"),
            ),
        )


def _write_state_to_db(conn: sqlite3.Connection, state: dict) -> None:
    for user in state.get("users", {}).values():
        if isinstance(user, dict) and user.get("id"):
            _write_user_row(conn, user)
    for user_id, trips in state.get("trips_by_user", {}).items():
        for position, trip in enumerate(trips if isinstance(trips, list) else []):
            if not isinstance(trip, dict) or not trip.get("id"):
                continue
            _write_trip_row(conn, trip)
            conn.execute(
                """
                INSERT OR REPLACE INTO user_trips (user_id, trip_id, position)
                VALUES (?, ?, ?)
                """,
                (user_id, str(trip["id"]), position),
            )
    for user_id, cards in state.get("cards_by_user", {}).items():
        _write_cards_for_user(conn, user_id, cards if isinstance(cards, list) else [])


def _load_db_state() -> None:
    _init_db()
    with _DB_LOCK, _db_connect() as conn:
        USERS.clear()
        TRIPS_BY_USER.clear()
        CARD_PROFILES_BY_USER.clear()

        user_cols = _table_columns(conn, "users")
        has_kakao = "kakao_user_id" in user_cols
        has_nickname = "nickname" in user_cols
        if has_kakao and has_nickname:
            user_query = (
                "SELECT id, name, nickname, phone_number, access_token, kakao_user_id, "
                "settlement_bank_name, settlement_account_number, settlement_account_holder "
                "FROM users"
            )
        elif has_kakao:
            user_query = "SELECT id, name, phone_number, access_token, kakao_user_id FROM users"
        elif has_nickname:
            user_query = "SELECT id, name, nickname, phone_number, access_token FROM users"
        else:
            user_query = "SELECT id, name, phone_number, access_token FROM users"
        for row in conn.execute(user_query):
            if has_kakao and has_nickname:
                (
                    user_id,
                    name,
                    nickname,
                    phone_number,
                    access_token,
                    kakao_user_id,
                    settlement_bank_name,
                    settlement_account_number,
                    settlement_account_holder,
                ) = row
            elif has_kakao:
                user_id, name, phone_number, access_token, kakao_user_id = row
                nickname = ""
                settlement_bank_name = settlement_account_number = settlement_account_holder = ""
            elif has_nickname:
                user_id, name, nickname, phone_number, access_token = row
                kakao_user_id = None
                settlement_bank_name = settlement_account_number = settlement_account_holder = ""
            else:
                user_id, name, phone_number, access_token = row
                nickname = ""
                kakao_user_id = None
                settlement_bank_name = settlement_account_number = settlement_account_holder = ""
            entry = {
                "id": user_id,
                "name": name,
                "nickname": nickname or "",
                "phoneNumber": phone_number,
                "settlementBankName": settlement_bank_name or "",
                "settlementAccountNumber": settlement_account_number or "",
                "settlementAccountHolder": settlement_account_holder or "",
                "accessToken": access_token,
            }
            if kakao_user_id:
                entry["kakaoUserId"] = str(kakao_user_id)
            USERS[user_id] = entry
            TRIPS_BY_USER[user_id] = []
            CARD_PROFILES_BY_USER[user_id] = []

        trip_map: dict[str, dict] = {}
        trip_cols = _table_columns(conn, "trips")
        has_host_user_id = "host_user_id" in trip_cols
        has_countries = "countries_json" in trip_cols
        trip_query = (
            """
            SELECT id, name, start_date, end_date, host_name, host_user_id,
                   invite_code, countries_json, tile_color, cover_image_path
            FROM trips
            """
            if has_host_user_id and has_countries
            else """
            SELECT id, name, start_date, end_date, host_name, host_user_id,
                   invite_code, tile_color, cover_image_path
            FROM trips
            """
            if has_host_user_id
            else """
            SELECT id, name, start_date, end_date, host_name,
                   invite_code, tile_color, cover_image_path
            FROM trips
            """
        )
        for row in conn.execute(trip_query):
            if has_host_user_id and has_countries:
                (
                    trip_id,
                    name,
                    start_date,
                    end_date,
                    host_name,
                    host_user_id,
                    invite_code,
                    countries_json,
                    tile_color,
                    cover_image_path,
                ) = row
            elif has_host_user_id:
                (
                    trip_id,
                    name,
                    start_date,
                    end_date,
                    host_name,
                    host_user_id,
                    invite_code,
                    tile_color,
                    cover_image_path,
                ) = row
                countries_json = "[]"
            else:
                (
                    trip_id,
                    name,
                    start_date,
                    end_date,
                    host_name,
                    invite_code,
                    tile_color,
                    cover_image_path,
                ) = row
                host_user_id = None
                countries_json = "[]"
            display_host_name = _participant_display_name(host_name, host_user_id)
            trip_map[trip_id] = {
                "id": trip_id,
                "name": name,
                "startDate": start_date,
                "endDate": end_date,
                "participants": [],
                "countries": _json_loads(countries_json, []),
                "hostName": display_host_name,
                "hostUserId": host_user_id,
                "inviteCode": invite_code,
                "tileColor": tile_color,
                "coverImagePath": _valid_media_reference(cover_image_path),
                "receipts": [],
            }

        participant_cols = _table_columns(conn, "trip_participants")
        has_participant_user_id = "user_id" in participant_cols
        participant_query = (
            """
            SELECT trip_id, user_id, name
            FROM trip_participants
            ORDER BY trip_id, position
            """
            if has_participant_user_id
            else """
            SELECT trip_id, name
            FROM trip_participants
            ORDER BY trip_id, position
            """
        )
        for row in conn.execute(participant_query):
            if has_participant_user_id:
                trip_id, participant_user_id, name = row
            else:
                trip_id, name = row
                participant_user_id = None
            if trip_id in trip_map:
                trip_map[trip_id]["participants"].append(
                    _participant_display_name(name, participant_user_id)
                )
        for trip in trip_map.values():
            trip["participants"] = _dedupe_names(list(trip.get("participants") or []))

        receipt_map: dict[str, dict] = {}
        for row in conn.execute(
            """
            SELECT id, trip_id, store_name, amount, date, category, image_path,
                   paid_by, currency_code, payment_method, card_type, card_issuer,
                   bank_name, card_brand, card_last4, card_brand_fee_rate,
                   card_issuer_fee_rate, issuer_fee_type, issuer_fee_fixed_usd,
                   cash_exchange_fee_rate, cash_krw_per_unit,
                   payment_correction_rate, estimated_krw_amount,
                   actual_krw_amount, local_to_usd_rate, usd_amount,
                   usd_to_krw_rate, base_krw_amount, exchange_rate_source,
                   rate_date_label, confidence, warnings_json, recognition_json
            FROM receipts
            ORDER BY rowid
            """
        ):
            (
                receipt_id,
                trip_id,
                store_name,
                amount,
                date,
                category,
                image_path,
                paid_by,
                currency_code,
                payment_method,
                card_type,
                card_issuer,
                bank_name,
                card_brand,
                card_last4,
                brand_fee,
                issuer_fee,
                issuer_fee_type,
                issuer_fee_fixed_usd,
                cash_fee,
                cash_rate,
                correction,
                estimated_krw,
                actual_krw,
                local_to_usd,
                usd_amount,
                usd_to_krw,
                base_krw,
                exchange_source,
                rate_label,
                confidence,
                warnings_json,
                recognition_json,
            ) = row
            receipt = {
                "id": receipt_id,
                "storeName": store_name,
                "amount": amount,
                "date": date,
                "category": category,
                "imagePath": image_path,
                "paidBy": _participant_display_name(paid_by),
                "currencyCode": currency_code,
                "paymentMethod": payment_method,
                "cardType": _normalize_card_type(card_type),
                "cardIssuer": card_issuer,
                "bankName": bank_name,
                "cardBrand": card_brand,
                "cardLast4": card_last4,
                "cardBrandFeeRate": brand_fee,
                "cardIssuerFeeRate": issuer_fee,
                "issuerFeeType": issuer_fee_type,
                "issuerFeeFixedUsd": issuer_fee_fixed_usd,
                "cashExchangeFeeRate": cash_fee,
                "cashKrwPerUnit": cash_rate,
                "paymentCorrectionRate": correction,
                "estimatedKrwAmount": estimated_krw,
                "actualKrwAmount": actual_krw,
                "localToUsdRate": local_to_usd,
                "usdAmount": usd_amount,
                "usdToKrwRate": usd_to_krw,
                "baseKrwAmount": base_krw,
                "exchangeRateSource": exchange_source,
                "rateDateLabel": rate_label,
                "confidence": confidence,
                "warnings": _json_loads(warnings_json, []),
                "recognition": _json_loads(recognition_json, {}),
                "items": [],
            }
            receipt_map[receipt_id] = receipt
            if trip_id in trip_map:
                trip_map[trip_id]["receipts"].append(receipt)

        item_map: dict[str, dict] = {}
        for row in conn.execute(
            """
            SELECT id, receipt_id, name, translated_name, quantity, unit_price, line_total, category
            FROM receipt_items
            ORDER BY receipt_id, item_index
            """
        ):
            item_id, receipt_id, name, translated_name, quantity, unit_price, line_total, category = row
            item = {
                "id": item_id,
                "name": name,
                "translatedName": translated_name,
                "quantity": quantity,
                "unitPrice": unit_price,
                "lineTotal": line_total,
                "category": category,
                "quantityByPerson": {},
            }
            item_map[item_id] = item
            if receipt_id in receipt_map:
                receipt_map[receipt_id]["items"].append(item)

        for item_id, person_name, quantity in conn.execute(
            """
            SELECT receipt_item_id, person_name, quantity
            FROM receipt_item_splits
            """
        ):
            if item_id in item_map:
                item_map[item_id]["quantityByPerson"][
                    _participant_display_name(person_name)
                ] = quantity

        for user_id, trip_id in conn.execute(
            """
            SELECT user_id, trip_id
            FROM user_trips
            ORDER BY user_id, position
            """
        ):
            if user_id in TRIPS_BY_USER and trip_id in trip_map:
                TRIPS_BY_USER[user_id].append(deepcopy(trip_map[trip_id]))

        for row in conn.execute(
            """
            SELECT id, user_id, name, company, brand, card_type, last4,
                   issuer_fee_rate, issuer_fee_type, issuer_fee_fixed_usd,
                   brand_fee_rate, network_fee_waived, issuer_fee_waived,
                   product_override_note, fee_research_status,
                   fee_research_summary, fee_research_sources_json,
                   fee_research_checked_at, fee_research_error
            FROM card_profiles
            ORDER BY rowid
            """
        ):
            (
                card_id,
                user_id,
                name,
                company,
                brand,
                card_type,
                last4,
                issuer_fee,
                issuer_fee_type,
                issuer_fee_fixed_usd,
                brand_fee,
                network_fee_waived,
                issuer_fee_waived,
                product_override_note,
                fee_research_status,
                fee_research_summary,
                fee_research_sources_json,
                fee_research_checked_at,
                fee_research_error,
            ) = row
            CARD_PROFILES_BY_USER.setdefault(user_id, []).append(
                {
                    "id": card_id,
                    "name": name,
                    "company": company,
                    "brand": brand,
                    "cardType": _normalize_card_type(card_type),
                    "last4": last4,
                    "issuerFeeRate": issuer_fee,
                    "issuerFeeType": issuer_fee_type,
                    "issuerFeeFixedUsd": issuer_fee_fixed_usd,
                    "brandFeeRate": brand_fee,
                    "networkFeeWaived": bool(network_fee_waived),
                    "issuerFeeWaived": bool(issuer_fee_waived),
                    "productOverrideNote": product_override_note,
                    "feeResearchStatus": fee_research_status or "idle",
                    "feeResearchSummary": fee_research_summary,
                    "feeResearchSources": _json_loads(fee_research_sources_json, []),
                    "feeResearchCheckedAt": fee_research_checked_at,
                    "feeResearchError": fee_research_error,
                }
            )


def _save_user(user: dict) -> None:
    with _DB_LOCK, _db_connect() as conn:
        _write_user_row(conn, user)


def _save_trips_for_user(user_id: str) -> None:
    with _DB_LOCK, _db_connect() as conn:
        conn.execute("DELETE FROM user_trips WHERE user_id = ?", (user_id,))
        for position, trip in enumerate(TRIPS_BY_USER.setdefault(user_id, [])):
            if not trip.get("id"):
                continue
            _write_trip_row(conn, trip)
            conn.execute(
                """
                INSERT OR REPLACE INTO user_trips (user_id, trip_id, position)
                VALUES (?, ?, ?)
                """,
                (user_id, str(trip["id"]), position),
            )


def _save_cards_for_user(user_id: str) -> None:
    with _DB_LOCK, _db_connect() as conn:
        _write_cards_for_user(conn, user_id, CARD_PROFILES_BY_USER.setdefault(user_id, []))


def _fee_rule_from_db(kind: str, value: object) -> tuple[str, float] | None:
    key = _normalize_fee_key(value)
    if not key:
        return None
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT label, rate, aliases_json
                FROM card_fee_catalog
                WHERE kind = ?
                """,
                (kind,),
            ).fetchall()
    except sqlite3.Error:
        return None

    for label, rate, aliases_json in rows:
        aliases = _json_loads(aliases_json, [])
        candidates = [label, *(aliases if isinstance(aliases, list) else [])]
        for candidate in candidates:
            candidate_key = _normalize_fee_key(candidate)
            if key == candidate_key or key in candidate_key or candidate_key in key:
                return str(label), float(rate)
    return None


def _issuer_fee_rate_for(value: object) -> float | None:
    db_rule = _fee_rule_from_db("issuer", value)
    if db_rule is not None:
        return db_rule[1]
    rule = _find_fee_rule(value, CARD_ISSUER_FEE_RATES)
    return rule[1] if rule else None


def _brand_fee_rate_for(value: object) -> float | None:
    db_rule = _fee_rule_from_db("brand", value)
    if db_rule is not None:
        return db_rule[1]
    rule = _find_fee_rule(value, CARD_BRAND_FEE_RATES)
    return rule[1] if rule else None


def _issuer_policy_from_db(
    issuer_label: str,
    card_type: str,
    brand: object = None,
) -> dict | None:
    issuer_key = _normalize_fee_key(issuer_label)
    brand_key = _normalize_fee_key(brand)
    if not issuer_key:
        return None
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT issuer_label, card_type, brand_label, fee_type,
                       fee_rate, fixed_usd, source_note
                FROM card_issuer_fee_policies
                WHERE card_type = ?
                """,
                (card_type,),
            ).fetchall()
    except sqlite3.Error:
        return None

    fallback: dict | None = None
    for row in rows:
        label, row_card_type, brand_label, fee_type, fee_rate, fixed_usd, note = row
        if row_card_type != card_type:
            continue
        label_key = _normalize_fee_key(label)
        if not (issuer_key == label_key or issuer_key in label_key or label_key in issuer_key):
            continue
        item = {
            "type": str(fee_type or "rate"),
            "rate": float(fee_rate or 0.0),
            "fixed_usd": fixed_usd,
            "note": note,
        }
        if brand_label:
            row_brand_key = _normalize_fee_key(brand_label)
            if brand_key and (
                brand_key == row_brand_key
                or brand_key in row_brand_key
                or row_brand_key in brand_key
            ):
                return item
            continue
        fallback = item
    return fallback


def _card_products_from_db() -> list[dict]:
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT p.id, p.name, p.company, p.brand, p.card_type,
                       p.category, p.is_available, p.source_url,
                       p.source_checked_at,
                       o.network_fee_waived, o.issuer_fee_waived,
                       o.override_network_fee_rate, o.override_issuer_fee_type,
                       o.override_issuer_fee_rate, o.override_issuer_fee_fixed_usd,
                       o.waiver_type, o.foreign_wallet_required, o.source_note
                FROM card_products p
                LEFT JOIN card_product_fee_overrides o
                  ON o.product_id = p.id AND o.transaction_type = 'purchase'
                WHERE p.card_type IN ('credit', 'check')
                ORDER BY p.company, p.card_type, p.name
                """
            ).fetchall()
    except sqlite3.Error:
        return []

    products: list[dict] = []
    for row in rows:
        (
            product_id,
            name,
            company,
            brand,
            card_type,
            category,
            is_available,
            source_url,
            source_checked_at,
            network_fee_waived,
            issuer_fee_waived,
            override_network_fee_rate,
            override_issuer_fee_type,
            override_issuer_fee_rate,
            override_issuer_fee_fixed_usd,
            waiver_type,
            foreign_wallet_required,
            source_note,
        ) = row
        item = {
            "id": product_id,
            "name": name,
            "company": company,
            "brand": brand,
            "cardType": card_type,
            "category": category,
            "isAvailable": bool(is_available),
            "sourceUrl": source_url,
            "sourceCheckedAt": source_checked_at,
        }
        if source_note:
            item["feeOverride"] = {
                "networkFeeWaived": bool(network_fee_waived),
                "issuerFeeWaived": bool(issuer_fee_waived),
                "overrideNetworkFeeRate": override_network_fee_rate,
                "overrideIssuerFeeType": override_issuer_fee_type,
                "overrideIssuerFeeRate": override_issuer_fee_rate,
                "overrideIssuerFeeFixedUsd": override_issuer_fee_fixed_usd,
                "waiverType": waiver_type,
                "foreignWalletRequired": bool(foreign_wallet_required),
                "sourceNote": source_note,
            }
        products.append(item)
    return products


def _product_override_for_card(card: dict) -> dict | None:
    name_key = _normalize_fee_key(card.get("name"))
    company_key = _normalize_fee_key(card.get("company"))
    card_type = _normalize_card_type(card.get("cardType") or card.get("card_type"))
    if not name_key:
        return None
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT p.name, p.company, p.card_type,
                       o.network_fee_waived, o.issuer_fee_waived,
                       o.override_network_fee_rate, o.override_issuer_fee_type,
                       o.override_issuer_fee_rate, o.override_issuer_fee_fixed_usd,
                       o.waiver_type, o.foreign_wallet_required, o.source_note
                FROM card_products p
                JOIN card_product_fee_overrides o
                  ON o.product_id = p.id AND o.transaction_type = 'purchase'
                WHERE p.card_type = ?
                """,
                (card_type,),
            ).fetchall()
    except sqlite3.Error:
        return None

    best: dict | None = None
    for row in rows:
        (
            product_name,
            company,
            row_card_type,
            network_fee_waived,
            issuer_fee_waived,
            override_network_fee_rate,
            override_issuer_fee_type,
            override_issuer_fee_rate,
            override_issuer_fee_fixed_usd,
            waiver_type,
            foreign_wallet_required,
            source_note,
        ) = row
        product_key = _normalize_fee_key(product_name)
        row_company_key = _normalize_fee_key(company)
        if not (name_key == product_key or name_key in product_key or product_key in name_key):
            continue
        if company_key and row_company_key and not (
            company_key == row_company_key
            or company_key in row_company_key
            or row_company_key in company_key
        ):
            continue
        best = {
            "cardType": row_card_type,
            "networkFeeWaived": bool(network_fee_waived),
            "issuerFeeWaived": bool(issuer_fee_waived),
            "overrideNetworkFeeRate": override_network_fee_rate,
            "overrideIssuerFeeType": override_issuer_fee_type,
            "overrideIssuerFeeRate": override_issuer_fee_rate,
            "overrideIssuerFeeFixedUsd": override_issuer_fee_fixed_usd,
            "waiverType": waiver_type,
            "foreignWalletRequired": bool(foreign_wallet_required),
            "sourceNote": source_note,
        }
        if name_key == product_key:
            return best
    return best


def _card_fee_policy_for(card: dict) -> dict:
    card_type = _normalize_card_type(card.get("cardType") or card.get("card_type"))
    issuer_rule = _fee_rule_from_db("issuer", card.get("company")) or _find_fee_rule(
        card.get("company"),
        CARD_ISSUER_FEE_RATES,
    )
    issuer_label = issuer_rule[0] if issuer_rule else str(card.get("company") or "")
    brand_rule = _fee_rule_from_db("brand", card.get("brand")) or _find_fee_rule(
        card.get("brand"),
        CARD_BRAND_FEE_RATES,
    )
    brand_rate = brand_rule[1] if brand_rule else 0.0
    issuer_policy = _issuer_policy_from_db(
        issuer_label,
        card_type,
        card.get("brand"),
    ) or _issuer_policy_for(issuer_label, card_type, card.get("brand"))
    issuer_fee_type = str(issuer_policy.get("type") or "rate")
    issuer_fixed_usd = issuer_policy.get("fixed_usd")
    issuer_rate = float(issuer_policy.get("rate") or 0.0)
    explicit_brand_rate = _first_present(card.get("brandFeeRate"), card.get("brand_fee_rate"))
    explicit_issuer_rate = _first_present(card.get("issuerFeeRate"), card.get("issuer_fee_rate"))
    explicit_issuer_type = card.get("issuerFeeType") or card.get("issuer_fee_type")
    explicit_issuer_fixed = _first_present(card.get("issuerFeeFixedUsd"), card.get("issuer_fee_fixed_usd"))
    if explicit_brand_rate is not None:
        brand_rate = _as_float(explicit_brand_rate, brand_rate)
    if explicit_issuer_rate is not None:
        issuer_rate = _as_float(explicit_issuer_rate, issuer_rate)
    if explicit_issuer_type:
        issuer_fee_type = str(explicit_issuer_type)
    if explicit_issuer_fixed is not None:
        issuer_fixed_usd = _as_float(explicit_issuer_fixed, 0.0)

    network_waived = bool(card.get("networkFeeWaived") or card.get("network_fee_waived"))
    issuer_waived = bool(card.get("issuerFeeWaived") or card.get("issuer_fee_waived"))
    product_note = card.get("productOverrideNote") or card.get("product_override_note")
    product_override = _product_override_for_card(card)
    if product_override:
        if product_override.get("overrideNetworkFeeRate") is not None:
            brand_rate = float(product_override["overrideNetworkFeeRate"] or 0.0)
        if product_override.get("overrideIssuerFeeType"):
            issuer_fee_type = str(product_override["overrideIssuerFeeType"])
        if product_override.get("overrideIssuerFeeRate") is not None:
            issuer_rate = float(product_override["overrideIssuerFeeRate"] or 0.0)
        if product_override.get("overrideIssuerFeeFixedUsd") is not None:
            issuer_fixed_usd = product_override["overrideIssuerFeeFixedUsd"]
        network_waived = network_waived or bool(product_override.get("networkFeeWaived"))
        issuer_waived = issuer_waived or bool(product_override.get("issuerFeeWaived"))
        product_note = product_note or product_override.get("sourceNote")
    elif card_type == "prepaid" or issuer_label in FINTECH_TRAVEL_PROVIDERS or _is_travel_fee_exception(card.get("name")):
        network_waived = True
        issuer_waived = True
        product_note = product_note or "여행 특화/외화머니 카드로 기본 해외결제 수수료 면제 후보"
    elif issuer_policy.get("note"):
        product_note = product_note or str(issuer_policy["note"])

    return {
        "cardType": card_type,
        "issuerFeeRate": 0.0 if issuer_waived else issuer_rate,
        "issuerFeeType": "none" if issuer_waived else issuer_fee_type,
        "issuerFeeFixedUsd": None if issuer_waived else issuer_fixed_usd,
        "brandFeeRate": 0.0 if network_waived else brand_rate,
        "networkFeeWaived": network_waived,
        "issuerFeeWaived": issuer_waived,
        "productOverrideNote": product_note,
    }


def _card_with_research_defaults(card: dict) -> dict:
    card.setdefault("feeResearchStatus", "idle")
    card.setdefault("feeResearchSummary", None)
    card.setdefault("feeResearchSources", [])
    card.setdefault("feeResearchCheckedAt", None)
    card.setdefault("feeResearchError", None)
    return card


def _merge_existing_card_research(user_id: str, card: dict) -> dict:
    existing = next(
        (item for item in CARD_PROFILES_BY_USER.get(user_id, []) if item.get("id") == card.get("id")),
        None,
    )
    if existing:
        for key in (
            "feeResearchStatus",
            "feeResearchSummary",
            "feeResearchSources",
            "feeResearchCheckedAt",
            "feeResearchError",
        ):
            if key not in card and key in existing:
                card[key] = deepcopy(existing[key])
    return _card_with_research_defaults(card)


def _maybe_schedule_card_fee_research(user_id: str, card_id: str) -> None:
    if not settings.card_fee_research_enabled:
        return
    try:
        asyncio.get_running_loop().create_task(
            asyncio.to_thread(_research_card_fee_sync, user_id, card_id)
        )
    except RuntimeError:
        return


def _set_card_research_state(
    user_id: str,
    card_id: str,
    *,
    status: str,
    summary: str | None = None,
    sources: list[dict] | None = None,
    error: str | None = None,
    updates: dict | None = None,
) -> None:
    cards = CARD_PROFILES_BY_USER.setdefault(user_id, [])
    for index, card in enumerate(cards):
        if card.get("id") != card_id:
            continue
        next_card = deepcopy(card)
        if updates:
            next_card.update(updates)
        next_card["feeResearchStatus"] = status
        next_card["feeResearchSummary"] = summary
        next_card["feeResearchSources"] = sources or []
        next_card["feeResearchCheckedAt"] = datetime.now(timezone.utc).isoformat()
        next_card["feeResearchError"] = error
        cards[index] = next_card
        _save_cards_for_user(user_id)
        return


def _research_card_fee_sync(user_id: str, card_id: str) -> None:
    card = next(
        (deepcopy(item) for item in CARD_PROFILES_BY_USER.get(user_id, []) if item.get("id") == card_id),
        None,
    )
    if not card or not str(card.get("name") or "").strip():
        return
    _set_card_research_state(user_id, card_id, status="running")
    try:
        evidence = _collect_card_fee_evidence(card)
        if not evidence:
            raise RuntimeError("수수료 근거 문서를 찾지 못했습니다.")
        extracted = _extract_card_fee_with_llm(card, evidence)
        updates = _card_fee_updates_from_research(extracted)
        merged = deepcopy(card)
        merged.update(updates)
        updates.update(_card_fee_policy_for(merged))
        status = "done" if extracted.get("status") == "found" else "uncertain"
        _set_card_research_state(
            user_id,
            card_id,
            status=status,
            summary=str(extracted.get("summary") or "").strip() or None,
            sources=extracted.get("sources") if isinstance(extracted.get("sources"), list) else evidence,
            updates=updates,
        )
    except Exception as exc:
        _set_card_research_state(
            user_id,
            card_id,
            status="failed",
            error=str(exc)[:240],
        )


def _collect_card_fee_evidence(card: dict) -> list[dict]:
    query = " ".join(
        str(part).strip()
        for part in (
            card.get("company"),
            card.get("name"),
            card.get("brand"),
            "해외이용 수수료 해외서비스수수료 국제브랜드 수수료 상품설명서",
        )
        if str(part or "").strip()
    )
    search_url = f"https://duckduckgo.com/html/?q={quote_plus(query)}"
    html_text = _fetch_text(search_url, timeout=8)
    candidates = _parse_search_results(html_text)
    official = sorted(candidates, key=lambda item: _card_source_priority(item.get("url")))
    limit = max(1, int(settings.card_fee_research_max_sources or 4))
    return [
        {
            "title": item.get("title"),
            "url": item.get("url"),
            "snippet": item.get("snippet"),
        }
        for item in official[:limit]
    ]


def _parse_search_results(page: str) -> list[dict]:
    results: list[dict] = []
    blocks = re.findall(r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>', page, re.S)
    snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</a>|class="result__snippet"[^>]*>(.*?)</div>', page, re.S)
    for index, (raw_url, raw_title) in enumerate(blocks[:8]):
        url = _normalize_search_url(html.unescape(raw_url))
        if not url:
            continue
        snippet_raw = ""
        if index < len(snippets):
            snippet_raw = next((part for part in snippets[index] if part), "")
        results.append(
            {
                "title": _html_to_text(raw_title)[:160],
                "url": url,
                "snippet": _html_to_text(snippet_raw)[:260],
            }
        )
    return results


def _normalize_search_url(url: str) -> str:
    parsed = urlparse(url)
    if "duckduckgo.com" in parsed.netloc and "uddg=" in parsed.query:
        for part in parsed.query.split("&"):
            if part.startswith("uddg="):
                return unquote(part[5:])
    return url if parsed.scheme in {"http", "https"} else ""


def _card_source_priority(url: object) -> tuple[int, str]:
    host = urlparse(str(url or "")).netloc.lower()
    official_tokens = (
        "shinhancard.com",
        "kbcard.com",
        "hyundaicard.com",
        "samsungcard.com",
        "hanacard.co.kr",
        "lottecard.co.kr",
        "wooricard.com",
        "bccard.com",
        "nonghyup.com",
        "ibk.co.kr",
        "travel-wallet.com",
    )
    return (0 if any(token in host for token in official_tokens) else 1, host)


def _fetch_text(url: str, *, timeout: int) -> str:
    if not url:
        return ""
    try:
        request = Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 TripScript card fee research",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            },
        )
        with urlopen(request, timeout=timeout) as response:
            raw = response.read(900_000)
        return raw.decode("utf-8", errors="ignore")
    except (HTTPError, URLError, TimeoutError, ValueError):
        return ""


def _html_to_text(raw: str) -> str:
    text = re.sub(r"(?is)<(script|style).*?>.*?</\\1>", " ", raw)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _extract_card_fee_with_llm(card: dict, evidence: list[dict]) -> dict:
    prompt = (
        "대한민국 발급 카드의 해외 가맹점 결제 수수료를 근거 문서에서만 추출해 JSON으로 답하세요. "
        "모르면 null 또는 uncertain을 사용하고 추측하지 마세요. ATM/현금서비스/DCC는 제외합니다.\n"
        "Schema: {\"status\":\"found|uncertain\", \"issuerFeeType\":\"rate|fixed_usd|none|null\", "
        "\"issuerFeeRate\":number|null, \"issuerFeeFixedUsd\":number|null, "
        "\"brandFeeRate\":number|null, \"networkFeeWaived\":boolean|null, "
        "\"issuerFeeWaived\":boolean|null, \"productOverrideNote\":string|null, "
        "\"summary\":string, \"sources\":[{\"title\":string,\"url\":string}]}\n"
        "Rates must be decimals, so 1.0% is 0.01 and 0.25% is 0.0025.\n"
        f"Card: {json.dumps(card, ensure_ascii=False)}\n"
        f"Evidence: {json.dumps(evidence, ensure_ascii=False)[:18000]}"
    )
    url = settings.receipt_llm_base_url.rstrip("/") or "http://ollama:11434"
    payload = {
        "model": settings.card_fee_research_model,
        "stream": False,
        "format": "json",
        "messages": [
            {"role": "system", "content": "Return JSON only. Be conservative and source-grounded."},
            {"role": "user", "content": prompt},
        ],
        "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 900},
    }
    if settings.receipt_llm_keep_alive.strip():
        payload["keep_alive"] = settings.receipt_llm_keep_alive.strip()
    request = Request(
        f"{url}/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=int(settings.card_fee_research_timeout_seconds or 90)) as response:
        body = json.loads(response.read().decode("utf-8"))
    content = str(((body.get("message") or {}).get("content")) or "")
    return _json_object_from_llm_text(content)


def _json_object_from_llm_text(text: str) -> dict:
    stripped = text.strip()
    try:
        data = json.loads(stripped)
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", stripped, re.S)
        if not match:
            return {}
        data = json.loads(match.group(0))
        return data if isinstance(data, dict) else {}


def _card_fee_updates_from_research(extracted: dict) -> dict:
    updates: dict = {}
    for source_key, target_key in (
        ("issuerFeeRate", "issuerFeeRate"),
        ("issuerFeeType", "issuerFeeType"),
        ("issuerFeeFixedUsd", "issuerFeeFixedUsd"),
        ("brandFeeRate", "brandFeeRate"),
        ("networkFeeWaived", "networkFeeWaived"),
        ("issuerFeeWaived", "issuerFeeWaived"),
        ("productOverrideNote", "productOverrideNote"),
    ):
        value = extracted.get(source_key)
        if value is not None and value != "":
            if target_key in {"issuerFeeRate", "brandFeeRate"}:
                value = _normalize_fee_rate_value(value)
            updates[target_key] = value
    return updates


def _normalize_fee_rate_value(value: object) -> float:
    rate = _as_float(value, 0.0)
    if rate > 0.2:
        rate = rate / 100
    return rate


def _media_kind(value: object) -> str:
    kind = str(value or "receipt").strip().lower().replace("-", "_")
    return kind if kind in {"trip_cover", "receipt"} else "receipt"


def _valid_media_reference(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.startswith(("http://", "https://", "/api/v1/media/")):
        return text
    return None


def _media_path(kind: str, filename: str) -> Path:
    return MEDIA_ROOT / _media_kind(kind) / filename


def _media_public_path(kind: str, filename: str) -> str:
    return f"/api/v1/media/{_media_kind(kind)}/{filename}"


def _media_url(request: FastAPIRequest, public_path: str) -> str:
    return f"{str(request.base_url).rstrip('/')}{public_path}"


def _media_reference_to_path(value: object) -> tuple[Path, str]:
    text = str(value or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Receipt image path is required")

    parsed_path = urlparse(text).path if text.startswith(("http://", "https://")) else text
    if parsed_path.startswith("api/v1/media/"):
        parsed_path = f"/{parsed_path}"
    parts = parsed_path.split("/")
    if len(parts) != 6 or parts[1:4] != ["api", "v1", "media"]:
        raise HTTPException(
            status_code=400,
            detail="Only server media URLs from /api/v1/media/{kind}/{filename} can be recognized",
        )

    kind = _media_kind(parts[4])
    filename = parts[5]
    if not filename or "/" in filename or "\\" in filename:
        raise HTTPException(status_code=404, detail="Receipt image not found")

    target = _media_path(kind, filename)
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="Receipt image not found")
    if target.stat().st_size < 1024:
        raise HTTPException(status_code=400, detail="Image file is too small or corrupted")
    return target, _media_public_path(kind, filename)


def _media_extension(upload: UploadFile) -> str:
    suffix = Path(upload.filename or "").suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}:
        return ".jpg" if suffix in {".jpeg", ".heic", ".heif"} else suffix
    guessed = mimetypes.guess_extension(upload.content_type or "") or ".jpg"
    return ".jpg" if guessed == ".jpe" else guessed


def _validate_image_bytes(content: bytes) -> None:
    if len(content) < 1024:
        raise HTTPException(status_code=400, detail="Image file is too small or corrupted")
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        return
    source = np.frombuffer(content, dtype=np.uint8)
    image = cv2.imdecode(source, cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(status_code=400, detail="Invalid image file")
    height, width = image.shape[:2]
    if width < 64 or height < 64:
        raise HTTPException(status_code=400, detail="Image resolution is too small")


def _rate_date_from_value(value: object | None) -> str:
    raw = str(value or EXCHANGE_RATE_AS_OF_LABEL).strip()
    if "T" in raw:
        raw = raw.split("T", 1)[0]
    raw = raw[:10].replace(".", "-")
    parts = raw.split("-")
    if len(parts) == 3 and all(part.isdigit() for part in parts):
        return f"{int(parts[0]):04d}-{int(parts[1]):02d}-{int(parts[2]):02d}"
    return EXCHANGE_RATE_AS_OF_LABEL.replace(".", "-")


def _exchange_rate_row(currency_code: object, rate_date: str | None = None) -> tuple[float, str, str]:
    code = str(currency_code or "KRW").upper()
    date_key = _rate_date_from_value(rate_date)
    if code == "KRW":
        return 1.0, date_key, "identity"

    with _DB_LOCK, _db_connect() as conn:
        row = conn.execute(
            """
            SELECT krw_per_unit, as_of_label, source
            FROM exchange_rates
            WHERE currency_code = ? AND rate_date = ?
            """,
            (code, date_key),
        ).fetchone()
        if row is not None:
            return float(row[0]), str(row[1]), str(row[2])

    _fetch_exchange_rates_for_date(date_key, {code, "USD"})

    with _DB_LOCK, _db_connect() as conn:
        row = conn.execute(
            """
            SELECT krw_per_unit, as_of_label, source
            FROM exchange_rates
            WHERE currency_code = ? AND rate_date = ?
            """,
            (code, date_key),
        ).fetchone()
        if row is not None:
            return float(row[0]), str(row[1]), str(row[2])
        row = conn.execute(
            """
            SELECT krw_per_unit, as_of_label, source
            FROM exchange_rates
            WHERE currency_code = ?
            ORDER BY rate_date DESC
            LIMIT 1
            """,
            (code,),
        ).fetchone()
        if row is not None:
            return float(row[0]), str(row[1]), str(row[2])

    return KRW_PER_CURRENCY_UNIT.get(code, 1.0), EXCHANGE_RATE_AS_OF_LABEL, "temporary_static"


def _exchange_rate_for(currency_code: object, rate_date: str | None = None) -> float:
    return _exchange_rate_row(currency_code, rate_date)[0]


def _fetch_exchange_rates_for_date(rate_date: str, currencies: set[str]) -> None:
    needed = {c.upper() for c in currencies if c and c.upper() != "KRW"}
    if not needed:
        return
    query_date = _rate_date_from_value(rate_date)
    urls = [
        f"https://{query_date}.currency-api.pages.dev/v1/currencies/eur.json",
        "https://latest.currency-api.pages.dev/v1/currencies/eur.json",
    ]
    data: dict | None = None
    for url in urls:
        try:
            request = Request(url, headers={"User-Agent": "TripScript/0.1"})
            with urlopen(request, timeout=8) as response:
                data = json.loads(response.read().decode("utf-8"))
            break
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
            data = None
    if not data:
        return

    rates = data.get("eur")
    if not isinstance(rates, dict) or "krw" not in rates:
        return
    actual_date = _rate_date_from_value(data.get("date") or query_date)
    krw_per_eur = _as_float(rates.get("krw"))
    if krw_per_eur <= 0:
        return

    rows: list[tuple[str, float]] = [("EUR", krw_per_eur)]
    for code in needed | {"USD"}:
        if code == "EUR":
            continue
        per_eur = _as_float(rates.get(code.lower()))
        if per_eur > 0:
            rows.append((code, krw_per_eur / per_eur))

    with _DB_LOCK, _db_connect() as conn:
        for code, krw_per_unit in rows:
            conn.execute(
                """
                INSERT INTO exchange_rates
                    (currency_code, rate_date, krw_per_unit, as_of_label, source)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(currency_code, rate_date) DO UPDATE SET
                    krw_per_unit = excluded.krw_per_unit,
                    as_of_label = excluded.as_of_label,
                    source = excluded.source
                """,
                (
                    code,
                    query_date,
                    krw_per_unit,
                    actual_date,
                    "currency-api.pages.dev",
                ),
            )


def _estimate_receipt_payment(receipt: dict) -> dict:
    out = deepcopy(receipt)
    amount = _as_float(out.get("amount"))
    currency_code = str(out.get("currencyCode") or "KRW").upper()
    payment_method = "cash" if out.get("paymentMethod") == "cash" else "card"
    card_type = _normalize_card_type(out.get("cardType") or out.get("card_type"))
    rate_date = _rate_date_from_value(out.get("date"))
    out["currencyCode"] = currency_code
    out["paymentMethod"] = payment_method
    out["cardType"] = card_type

    usd_to_krw, usd_rate_label, usd_rate_source = _exchange_rate_row("USD", rate_date)
    krw_per_unit, rate_label, rate_source = _exchange_rate_row(currency_code, rate_date)
    is_krw = currency_code == "KRW"
    cash_krw_per_unit = _as_float(out.get("cashKrwPerUnit") or out.get("cash_krw_per_unit"))
    if payment_method == "cash" and cash_krw_per_unit > 0 and not is_krw:
        krw_per_unit = cash_krw_per_unit
        rate_label = "사용자 입력 환전 환율"
        rate_source = "user_cash_exchange_rate"
    local_to_usd = 0.0 if is_krw else krw_per_unit / usd_to_krw
    usd_amount = round(amount * local_to_usd, 2) if payment_method == "card" and not is_krw else 0.0
    base_krw = amount if is_krw else (usd_amount * usd_to_krw if payment_method == "card" else amount * krw_per_unit)

    brand_rule = _fee_rule_from_db("brand", out.get("cardBrand")) or _find_fee_rule(
        out.get("cardBrand"),
        CARD_BRAND_FEE_RATES,
    )
    issuer_rule = _fee_rule_from_db("issuer", out.get("cardIssuer")) or _find_fee_rule(
        out.get("cardIssuer"),
        CARD_ISSUER_FEE_RATES,
    )
    brand_fee = _as_float(out.get("cardBrandFeeRate"), brand_rule[1] if brand_rule else 0.0)
    issuer_label = issuer_rule[0] if issuer_rule else str(out.get("cardIssuer") or "")
    issuer_policy = _issuer_policy_from_db(
        issuer_label,
        card_type,
        out.get("cardBrand"),
    ) or _issuer_policy_for(issuer_label, card_type, out.get("cardBrand"))
    issuer_fee = _as_float(
        out.get("cardIssuerFeeRate"),
        issuer_policy.get("rate", issuer_rule[1] if issuer_rule else 0.0),
    )
    explicit_issuer_fee_type = out.get("issuerFeeType") or out.get("issuer_fee_type")
    issuer_fee_type = str(explicit_issuer_fee_type or issuer_policy.get("type") or "rate")
    issuer_fee_fixed_usd = _as_float(
        out.get("issuerFeeFixedUsd") or out.get("issuer_fee_fixed_usd") or issuer_policy.get("fixed_usd")
    )
    if not explicit_issuer_fee_type and issuer_fee_type in {"fixed_usd", "none"}:
        issuer_fee = 0.0
    if issuer_fee_type == "fixed_usd" and issuer_fee_fixed_usd <= 0:
        issuer_fee_type = "rate"
    cash_fee = _as_float(out.get("cashExchangeFeeRate"))
    correction = _as_float(out.get("paymentCorrectionRate"))
    if payment_method != "card" or is_krw:
        brand_fee = 0.0
        issuer_fee = 0.0
        issuer_fee_type = "none"
        issuer_fee_fixed_usd = 0.0
    if payment_method != "cash" or is_krw:
        cash_fee = 0.0
        cash_krw_per_unit = 0.0

    brand_fee_krw = base_krw * brand_fee
    issuer_fee_krw = (
        issuer_fee_fixed_usd * usd_to_krw
        if issuer_fee_type == "fixed_usd"
        else base_krw * issuer_fee
    )
    estimated = round(base_krw + brand_fee_krw + issuer_fee_krw + (base_krw * (cash_fee + correction)))
    out["localToUsdRate"] = local_to_usd
    out["usdAmount"] = usd_amount
    out["usdToKrwRate"] = usd_to_krw
    out["baseKrwAmount"] = base_krw
    out["cardBrandFeeRate"] = brand_fee if payment_method == "card" else None
    out["cardIssuerFeeRate"] = issuer_fee if payment_method == "card" else None
    out["issuerFeeType"] = issuer_fee_type if payment_method == "card" else None
    out["issuerFeeFixedUsd"] = issuer_fee_fixed_usd if issuer_fee_type == "fixed_usd" else None
    out["cardBrandFeeKrw"] = round(brand_fee_krw) if payment_method == "card" else None
    out["cardIssuerFeeKrw"] = round(issuer_fee_krw) if payment_method == "card" else None
    out["cashExchangeFeeRate"] = cash_fee if payment_method == "cash" else None
    out["cashKrwPerUnit"] = cash_krw_per_unit if payment_method == "cash" and not is_krw else None
    out["paymentCorrectionRate"] = correction or None
    out["estimatedKrwAmount"] = estimated
    out["exchangeRateSource"] = rate_source if currency_code != "KRW" else "identity"
    out["rateDateLabel"] = rate_label if currency_code != "KRW" else rate_date
    return out


def _normalize_trip_receipts(trip: dict) -> dict:
    out = deepcopy(trip)
    out["coverImagePath"] = _valid_media_reference(
        out.get("coverImagePath") or out.get("cover_image_path")
    )
    out["receipts"] = [
        _estimate_receipt_payment(receipt)
        for receipt in list(out.get("receipts") or [])
        if isinstance(receipt, dict)
    ]
    return out


def _receipt_amount_in_krw(receipt: dict) -> float:
    normalized = _estimate_receipt_payment(receipt)
    actual = normalized.get("actualKrwAmount")
    if actual is not None:
        return _as_float(actual)
    estimated = normalized.get("estimatedKrwAmount")
    if estimated is not None:
        return _as_float(estimated)
    amount = _as_float(normalized.get("amount"))
    code = str(normalized.get("currencyCode") or "KRW").upper()
    return amount if code == "KRW" else amount * _exchange_rate_for(code, normalized.get("date"))


def _trip_totals_by_currency(trip: dict) -> dict[str, float]:
    totals: dict[str, float] = {}
    for receipt in list(trip.get("receipts") or []):
        code = str(receipt.get("currencyCode") or "KRW").upper()
        totals[code] = totals.get(code, 0.0) + _as_float(receipt.get("amount"))
    return dict(
        sorted(
            totals.items(),
            key=lambda item: (item[0] != "KRW", item[0]),
        )
    )


def _owed_by_participant(trip: dict) -> dict[str, float]:
    participants = [str(name) for name in list(trip.get("participants") or []) if name]
    owed = {name: 0.0 for name in participants}
    if not participants:
        return owed

    def split_evenly(amount: float) -> None:
        each = amount / len(participants)
        for participant in participants:
            owed[participant] = owed.get(participant, 0.0) + each

    for raw_receipt in list(trip.get("receipts") or []):
        receipt = _estimate_receipt_payment(raw_receipt)
        receipt_total_krw = _receipt_amount_in_krw(receipt)
        items = [item for item in list(receipt.get("items") or []) if isinstance(item, dict)]
        if not items:
            split_evenly(receipt_total_krw)
            continue

        raw_item_owed = {name: 0.0 for name in participants}
        item_total_krw = 0.0
        krw_per_unit = _exchange_rate_for(receipt.get("currencyCode"), receipt.get("date"))

        for item in items:
            item_amount_krw = _as_float(item.get("lineTotal") or item.get("line_total")) * krw_per_unit
            item_total_krw += item_amount_krw
            split_map = item.get("quantityByPerson") or item.get("quantity_by_person") or {}
            targets: list[tuple[str, float]] = []
            if isinstance(split_map, dict):
                targets = [
                    (str(name), _as_float(quantity))
                    for name, quantity in split_map.items()
                    if str(name) in raw_item_owed and _as_float(quantity) > 0
                ]

            if not targets:
                each = item_amount_krw / len(participants)
                for participant in participants:
                    raw_item_owed[participant] = raw_item_owed.get(participant, 0.0) + each
                continue

            quantity_sum = sum(quantity for _, quantity in targets)
            if quantity_sum <= 0:
                continue
            for name, quantity in targets:
                raw_item_owed[name] = raw_item_owed.get(name, 0.0) + (
                    item_amount_krw * quantity / quantity_sum
                )

        if item_total_krw <= 0:
            split_evenly(receipt_total_krw)
            continue

        scale = receipt_total_krw / item_total_krw
        for participant in participants:
            owed[participant] = owed.get(participant, 0.0) + (
                raw_item_owed.get(participant, 0.0) * scale
            )

    return owed


def _receipt_owed_breakdown(receipt: dict, participants: list[str]) -> dict[str, float]:
    shares = {name: 0.0 for name in participants}
    if not participants:
        return shares

    normalized = _estimate_receipt_payment(receipt)
    receipt_total_krw = _receipt_amount_in_krw(normalized)
    items = [item for item in list(normalized.get("items") or []) if isinstance(item, dict)]
    if not items:
        each = receipt_total_krw / len(participants)
        return {name: each for name in participants}

    raw_shares = {name: 0.0 for name in participants}
    item_total_krw = 0.0
    krw_per_unit = _exchange_rate_for(normalized.get("currencyCode"), normalized.get("date"))
    for item in items:
        item_amount_krw = _as_float(item.get("lineTotal") or item.get("line_total")) * krw_per_unit
        item_total_krw += item_amount_krw
        split_map = item.get("quantityByPerson") or item.get("quantity_by_person") or {}
        targets: list[tuple[str, float]] = []
        if isinstance(split_map, dict):
            targets = [
                (str(name), _as_float(quantity))
                for name, quantity in split_map.items()
                if str(name) in raw_shares and _as_float(quantity) > 0
            ]
        if not targets:
            each = item_amount_krw / len(participants)
            for participant in participants:
                raw_shares[participant] += each
            continue
        quantity_sum = sum(quantity for _, quantity in targets)
        if quantity_sum <= 0:
            continue
        for name, quantity in targets:
            raw_shares[name] += item_amount_krw * quantity / quantity_sum

    if item_total_krw <= 0:
        each = receipt_total_krw / len(participants)
        return {name: each for name in participants}

    scale = receipt_total_krw / item_total_krw
    return {name: raw_shares.get(name, 0.0) * scale for name in participants}


def _receipt_item_share_breakdown(receipt: dict, participants: list[str]) -> list[dict]:
    normalized = _estimate_receipt_payment(receipt)
    receipt_total_krw = _receipt_amount_in_krw(normalized)
    items = [item for item in list(normalized.get("items") or []) if isinstance(item, dict)]
    if not items:
        return []

    krw_per_unit = _exchange_rate_for(normalized.get("currencyCode"), normalized.get("date"))
    item_rows: list[dict] = []
    item_total_krw = 0.0
    for item in items:
        item_amount_krw = _as_float(item.get("lineTotal") or item.get("line_total")) * krw_per_unit
        item_total_krw += item_amount_krw
        split_map = item.get("quantityByPerson") or item.get("quantity_by_person") or {}
        raw_shares = {name: 0.0 for name in participants}
        targets: list[tuple[str, float]] = []
        if isinstance(split_map, dict):
            targets = [
                (str(name), _as_float(quantity))
                for name, quantity in split_map.items()
                if str(name) in raw_shares and _as_float(quantity) > 0
            ]
        if targets:
            quantity_sum = sum(quantity for _, quantity in targets)
            if quantity_sum > 0:
                for name, quantity in targets:
                    raw_shares[name] = item_amount_krw * quantity / quantity_sum
        else:
            each = item_amount_krw / len(participants) if participants else 0
            for name in participants:
                raw_shares[name] = each
        item_rows.append(
            {
                "name": item.get("name") or "",
                "lineTotal": round(item_amount_krw),
                "participantShares": raw_shares,
            }
        )

    scale = receipt_total_krw / item_total_krw if item_total_krw > 0 else 1
    for row in item_rows:
        row["participantShares"] = {
            name: round(value * scale)
            for name, value in dict(row.get("participantShares") or {}).items()
            if abs(value * scale) >= 0.5
        }
    return item_rows


def _participant_accounts(participants: list[str]) -> dict[str, dict]:
    accounts: dict[str, dict] = {}
    for name in participants:
        user = _find_user_by_participant_name(name)
        accounts[name] = {
            "bankName": str((user or {}).get("settlementBankName") or ""),
            "accountNumber": str((user or {}).get("settlementAccountNumber") or ""),
            "accountHolder": str((user or {}).get("settlementAccountHolder") or ""),
        }
    return accounts


def _settlement_transfer_status_key(mode: object, from_name: object, to_name: object) -> tuple[str, str, str]:
    normalized_mode = str(mode or "net").strip().lower()
    if normalized_mode not in {"net", "gross"}:
        normalized_mode = "net"
    return (
        normalized_mode,
        str(from_name or "").strip(),
        str(to_name or "").strip(),
    )


def _settlement_transfer_statuses(trip_id: object) -> dict[tuple[str, str, str], dict]:
    if not trip_id:
        return {}
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT mode, from_name, to_name, completed, updated_by_user_id, updated_at
                FROM settlement_transfer_statuses
                WHERE trip_id = ?
                """,
                (str(trip_id),),
            ).fetchall()
    except sqlite3.Error:
        return {}
    return {
        _settlement_transfer_status_key(mode, from_name, to_name): {
            "completed": bool(completed),
            "updatedByUserId": updated_by_user_id,
            "updatedAt": updated_at,
        }
        for mode, from_name, to_name, completed, updated_by_user_id, updated_at in rows
    }


def _apply_settlement_transfer_statuses(
    transfers: list[dict],
    mode: str,
    statuses: dict[tuple[str, str, str], dict],
) -> list[dict]:
    out: list[dict] = []
    for transfer in transfers:
        item = dict(transfer)
        status_key = _settlement_transfer_status_key(
            mode,
            item.get("from"),
            item.get("to"),
        )
        status_item = statuses.get(status_key, {})
        item["completed"] = bool(status_item.get("completed"))
        item["statusUpdatedAt"] = status_item.get("updatedAt")
        item["statusUpdatedByUserId"] = status_item.get("updatedByUserId")
        out.append(item)
    return out


def _save_settlement_transfer_status(
    *,
    trip_id: str,
    mode: str,
    from_name: str,
    to_name: str,
    completed: bool,
    updated_by_user_id: str,
) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    with _DB_LOCK, _db_connect() as conn:
        conn.execute(
            """
            INSERT INTO settlement_transfer_statuses (
                trip_id, mode, from_name, to_name, completed, updated_by_user_id, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(trip_id, mode, from_name, to_name) DO UPDATE SET
                completed = excluded.completed,
                updated_by_user_id = excluded.updated_by_user_id,
                updated_at = excluded.updated_at
            """,
            (
                trip_id,
                mode,
                from_name,
                to_name,
                1 if completed else 0,
                updated_by_user_id,
                now,
            ),
        )
    return {
        "mode": mode,
        "from": from_name,
        "to": to_name,
        "completed": completed,
        "updatedAt": now,
        "updatedByUserId": updated_by_user_id,
    }


def _settlement_summary(trip: dict) -> dict:
    normalized_trip = _normalize_trip_receipts(trip)
    transfer_statuses = _settlement_transfer_statuses(normalized_trip.get("id"))
    participants = [
        str(name)
        for name in list(normalized_trip.get("participants") or [])
        if str(name).strip()
    ]
    owed = _owed_by_participant(normalized_trip)
    paid = {name: 0.0 for name in participants}
    for receipt in list(normalized_trip.get("receipts") or []):
        payer = str(receipt.get("paidBy") or "")
        if payer in paid:
            paid[payer] += _receipt_amount_in_krw(receipt)

    balances = []
    for name in participants:
        participant_paid = paid.get(name, 0.0)
        fair_share = owed.get(name, 0.0)
        balances.append(
            {
                "name": name,
                "paid": round(participant_paid),
                "fairShare": round(fair_share),
                "balance": round(participant_paid - fair_share),
            }
        )

    debtors = [
        {"name": item["name"], "amount": -float(item["balance"])}
        for item in balances
        if float(item["balance"]) < -0.5
    ]
    creditors = [
        {"name": item["name"], "amount": float(item["balance"])}
        for item in balances
        if float(item["balance"]) > 0.5
    ]
    transfers: list[dict] = []
    debtor_index = 0
    creditor_index = 0
    while debtor_index < len(debtors) and creditor_index < len(creditors):
        debtor = debtors[debtor_index]
        creditor = creditors[creditor_index]
        amount = min(float(debtor["amount"]), float(creditor["amount"]))
        rounded_amount = round(amount)
        if rounded_amount > 0:
            transfers.append(
                {
                    "from": debtor["name"],
                    "to": creditor["name"],
                    "amount": rounded_amount,
                }
            )
        debtor["amount"] = float(debtor["amount"]) - amount
        creditor["amount"] = float(creditor["amount"]) - amount
        if float(debtor["amount"]) < 0.5:
            debtor_index += 1
        if float(creditor["amount"]) < 0.5:
            creditor_index += 1

    receipt_breakdown = []
    gross_by_pair: dict[tuple[str, str], float] = {}
    for receipt in list(normalized_trip.get("receipts") or []):
        shares = _receipt_owed_breakdown(receipt, participants)
        payer = str(receipt.get("paidBy") or "")
        if payer in participants:
            for participant, share_amount in shares.items():
                if participant == payer or abs(share_amount) < 0.5:
                    continue
                key = (participant, payer)
                gross_by_pair[key] = gross_by_pair.get(key, 0.0) + float(share_amount)
        item_count = len(list(receipt.get("items") or []))
        receipt_breakdown.append(
            {
                "receiptId": receipt.get("id"),
                "storeName": receipt.get("storeName"),
                "paidBy": receipt.get("paidBy"),
                "amount": _as_float(receipt.get("amount")),
                "currencyCode": receipt.get("currencyCode"),
                "settlementKrwAmount": round(_receipt_amount_in_krw(receipt)),
                "itemCount": item_count,
                "splitBasis": "품목별 수량 배분" if item_count else "참여자 균등 배분",
                "participantShares": {
                    name: round(value) for name, value in shares.items() if abs(value) >= 0.5
                },
                "itemShares": _receipt_item_share_breakdown(receipt, participants),
            }
        )
    gross_transfers = [
        {"from": source, "to": target, "amount": round(amount)}
        for (source, target), amount in sorted(gross_by_pair.items())
        if round(amount) > 0
    ]
    transfers = _apply_settlement_transfer_statuses(transfers, "net", transfer_statuses)
    gross_transfers = _apply_settlement_transfer_statuses(
        gross_transfers,
        "gross",
        transfer_statuses,
    )

    return {
        "totalKrw": round(sum(_receipt_amount_in_krw(r) for r in normalized_trip.get("receipts") or [])),
        "totalsByCurrency": _trip_totals_by_currency(normalized_trip),
        "balances": balances,
        "grossTransfers": gross_transfers,
        "transfers": transfers,
        "participantAccounts": _participant_accounts(participants),
        "receiptBreakdown": receipt_breakdown,
        "calculationNotes": [
            "각 영수증은 실제 청구액이 있으면 실제 청구액을 우선 사용합니다.",
            "카드 결제는 현지통화→USD→KRW 및 브랜드/카드사 수수료를 반영한 정산 기준액을 사용합니다.",
            "품목별 수량 배분이 있으면 해당 비율을 쓰고, 품목이 없으면 참여자 균등 배분으로 계산합니다.",
            "원래 흐름은 영수증별 결제자에게 각 참여자의 부담액을 보내는 구조입니다.",
            "최종 상계는 참가자별 지출액과 부담액 차이를 최소 송금 관계로 정리한 결과입니다.",
        ],
    }


def _normalize_phone(phone: str) -> str:
    return "".join(ch for ch in phone if ch.isdigit())


def _public_user(user: dict) -> dict:
    return deepcopy(user)


_RECEIPT_PAYMENT_KEYS = {
    "storeName",
    "amount",
    "date",
    "category",
    "imagePath",
    "paidBy",
    "currencyCode",
    "paymentMethod",
    "cardType",
    "cardIssuer",
    "bankName",
    "cardBrand",
    "cardLast4",
    "cardBrandFeeRate",
    "cardIssuerFeeRate",
    "issuerFeeType",
    "issuerFeeFixedUsd",
    "cashExchangeFeeRate",
    "cashKrwPerUnit",
    "actualKrwAmount",
}


def _receipt_payment_fields_equal(original: dict, candidate: dict) -> bool:
    for key in _RECEIPT_PAYMENT_KEYS:
        if original.get(key) != candidate.get(key):
            return False
    return True


def _admin_expected_token() -> str:
    return settings.admin_api_token.strip()


def _require_admin(request: FastAPIRequest) -> None:
    if not settings.enable_admin_api:
        raise HTTPException(status_code=404, detail="Not found")
    expected = _admin_expected_token()
    authorization = str(request.headers.get("authorization") or "").strip()
    bearer_prefix = "Bearer "
    bearer_token = (
        authorization[len(bearer_prefix) :].strip()
        if authorization.lower().startswith(bearer_prefix.lower())
        else ""
    )
    submitted = str(request.headers.get("x-admin-token") or bearer_token).strip()
    if not expected or not secrets.compare_digest(submitted.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Admin token required")


def _admin_unique_trips() -> list[dict]:
    return sorted(_all_trips(), key=lambda trip: str(trip.get("name") or ""))


def _admin_receipts() -> list[dict]:
    items: list[dict] = []
    for trip in _admin_unique_trips():
        for receipt in list(trip.get("receipts") or []):
            estimated = _estimate_receipt_payment(receipt)
            items.append(
                {
                    "id": estimated.get("id"),
                    "tripId": trip.get("id"),
                    "tripName": trip.get("name"),
                    "storeName": estimated.get("storeName"),
                    "amount": estimated.get("amount"),
                    "currencyCode": estimated.get("currencyCode"),
                    "date": estimated.get("date"),
                    "paidBy": estimated.get("paidBy"),
                    "paymentMethod": estimated.get("paymentMethod"),
                    "estimatedKrwAmount": estimated.get("estimatedKrwAmount"),
                    "actualKrwAmount": estimated.get("actualKrwAmount"),
                    "settlementKrwAmount": _receipt_amount_in_krw(estimated),
                    "itemCount": len(list(estimated.get("items") or [])),
                    "imagePath": estimated.get("imagePath"),
                    "confidence": estimated.get("confidence"),
                    "warnings": list(estimated.get("warnings") or []),
                    "cardIssuer": estimated.get("cardIssuer"),
                    "cardBrand": estimated.get("cardBrand"),
                    "cardLast4": estimated.get("cardLast4"),
                    "cardIssuerFeeRate": estimated.get("cardIssuerFeeRate"),
                    "cardBrandFeeRate": estimated.get("cardBrandFeeRate"),
                    "exchangeRateSource": estimated.get("exchangeRateSource"),
                    "rateDateLabel": estimated.get("rateDateLabel"),
                    "recognition": estimated.get("recognition") or {},
                }
            )
    return sorted(items, key=lambda item: str(item.get("date") or ""), reverse=True)


def _admin_db_scalar(query: str, params: tuple = ()) -> int:
    try:
        with _DB_LOCK, _db_connect() as conn:
            row = conn.execute(query, params).fetchone()
    except sqlite3.Error:
        return 0
    if not row:
        return 0
    return int(row[0] or 0)


def _admin_storage_bytes() -> int:
    if not MEDIA_ROOT.exists():
        return 0
    return sum(path.stat().st_size for path in MEDIA_ROOT.rglob("*") if path.is_file())


def _admin_db_indexes() -> list[dict]:
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT name, tbl_name
                FROM sqlite_master
                WHERE type='index' AND name NOT LIKE 'sqlite_autoindex%'
                ORDER BY tbl_name, name
                """
            ).fetchall()
    except sqlite3.Error:
        return []
    return [{"name": row[0], "table": row[1]} for row in rows]


def _admin_counter(items: list[object]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in items:
        key = str(item or "unknown").strip() or "unknown"
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items(), key=lambda entry: entry[0]))


def _admin_currency_totals(receipts: list[dict]) -> dict[str, float]:
    totals: dict[str, float] = {}
    for receipt in receipts:
        code = str(receipt.get("currencyCode") or "KRW").upper()
        totals[code] = round(totals.get(code, 0.0) + _as_float(receipt.get("amount")), 2)
    return dict(sorted(totals.items(), key=lambda entry: entry[0]))


def _admin_recognition_stats(receipts: list[dict]) -> dict:
    recognized = [r for r in receipts if isinstance(r.get("recognition"), dict) and r.get("recognition")]
    durations = [
        _as_float((r.get("recognition") or {}).get("durationMs"), 0.0)
        for r in recognized
        if _as_float((r.get("recognition") or {}).get("durationMs"), 0.0) > 0
    ]
    warnings = sum(len(list(r.get("recognition", {}).get("warnings") or r.get("warnings") or [])) for r in recognized)
    providers = _admin_counter((r.get("recognition") or {}).get("llmProvider") for r in recognized)
    models = _admin_counter((r.get("recognition") or {}).get("llmModel") for r in recognized)
    strategies = _admin_counter((r.get("recognition") or {}).get("recognitionStrategy") for r in recognized)
    cache_hits = sum(1 for r in recognized if (r.get("recognition") or {}).get("cacheHit"))
    return {
        "totalRecognized": len(recognized),
        "avgDurationMs": round(sum(durations) / len(durations), 1) if durations else 0,
        "maxDurationMs": round(max(durations), 1) if durations else 0,
        "warningCount": warnings,
        "cacheHits": cache_hits,
        "providers": providers,
        "models": models,
        "strategies": strategies,
    }


def _admin_card_research_stats(cards: list[dict]) -> dict:
    return {
        "statusCounts": _admin_counter(card.get("feeResearchStatus") for card in cards),
        "researchedCount": sum(1 for card in cards if card.get("feeResearchStatus") in {"done", "uncertain"}),
        "failedCount": sum(1 for card in cards if card.get("feeResearchStatus") == "failed"),
    }


@router.get("/admin/summary")
async def admin_summary(request: FastAPIRequest) -> dict:
    _require_admin(request)
    trips = _admin_unique_trips()
    receipts = _admin_receipts()
    cards = [
        card
        for user_cards in CARD_PROFILES_BY_USER.values()
        for card in list(user_cards or [])
    ]
    db_indexes = _admin_db_indexes()
    total_krw = round(sum(float(item.get("settlementKrwAmount") or 0) for item in receipts))
    kakao_users = sum(1 for user in USERS.values() if str(user.get("kakaoUserId") or "").strip())
    return {
        "users": len(USERS),
        "kakaoUsers": kakao_users,
        "phoneUsers": max(len(USERS) - kakao_users, 0),
        "trips": len(trips),
        "receipts": len(receipts),
        "cards": len(cards),
        "mediaFiles": _admin_db_scalar("SELECT COUNT(*) FROM media_files"),
        "exchangeRates": _admin_db_scalar("SELECT COUNT(*) FROM exchange_rates"),
        "cardProducts": _admin_db_scalar("SELECT COUNT(*) FROM card_products"),
        "cardProductOverrides": _admin_db_scalar("SELECT COUNT(*) FROM card_product_fee_overrides"),
        "dbIndexes": db_indexes,
        "dbIndexCount": len(db_indexes),
        "totalSettlementKrw": total_krw,
        "mediaStorageBytes": _admin_storage_bytes(),
        "paymentMethodCounts": _admin_counter(item.get("paymentMethod") for item in receipts),
        "currencyTotals": _admin_currency_totals(receipts),
        "recognition": _admin_recognition_stats(receipts),
        "cardResearch": _admin_card_research_stats(cards),
        "system": {
            "appEnv": settings.app_env,
            "databaseUrl": settings.database_url,
            "storageDir": settings.storage_dir,
            "receiptRecognitionStrategy": settings.receipt_recognition_strategy,
            "receiptGeminiModel": settings.receipt_gemini_model,
            "receiptCloudFlattenEnabled": settings.receipt_cloud_llm_flatten_enabled,
            "cardFeeResearchEnabled": settings.card_fee_research_enabled,
            "cardFeeResearchModel": settings.card_fee_research_model,
        },
        "latestReceipts": receipts[:5],
        "latestTrips": [
            {
                "id": trip.get("id"),
                "name": trip.get("name"),
                "hostName": trip.get("hostName"),
                "participantCount": len(list(trip.get("participants") or [])),
                "receiptCount": len(list(trip.get("receipts") or [])),
                "totalKrw": round(sum(_receipt_amount_in_krw(r) for r in list(trip.get("receipts") or []))),
            }
            for trip in trips[:5]
        ],
    }


@router.get("/admin/users")
async def admin_users(request: FastAPIRequest) -> dict:
    _require_admin(request)
    items = []
    for user_id, user in USERS.items():
        user_trips = TRIPS_BY_USER.setdefault(user_id, [])
        user_cards = CARD_PROFILES_BY_USER.setdefault(user_id, [])
        items.append(
            {
                "id": user_id,
                "name": user.get("name"),
                "nickname": user.get("nickname"),
                "displayName": _user_display_name(user),
                "phoneNumber": user.get("phoneNumber"),
                "kakaoUserId": user.get("kakaoUserId"),
                "isKakaoLinked": bool(str(user.get("kakaoUserId") or "").strip()),
                "tripCount": len(user_trips),
                "cardCount": len(user_cards),
            }
        )
    return {"items": sorted(items, key=lambda item: str(item.get("displayName") or item.get("name") or ""))}


@router.post("/admin/users", status_code=status.HTTP_201_CREATED)
async def admin_create_user(request: FastAPIRequest, payload: dict) -> dict:
    _require_admin(request)
    name = str(payload.get("name") or "").strip()
    phone_number = str(payload.get("phoneNumber") or payload.get("phone_number") or "")
    normalized_phone = _normalize_phone(phone_number)
    if not name or not normalized_phone:
        raise HTTPException(status_code=400, detail="Name and phoneNumber are required")
    existing = _find_user(name, normalized_phone)
    if existing is not None:
        return _public_user(existing)
    return _public_user(_create_user(name, normalized_phone))


@router.delete("/admin/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def admin_delete_user(request: FastAPIRequest, user_id: str) -> Response:
    _require_admin(request)
    if not _delete_user_account(user_id):
        raise HTTPException(status_code=404, detail="User not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/admin/trips")
async def admin_trips(request: FastAPIRequest) -> dict:
    _require_admin(request)
    items = []
    for trip in _admin_unique_trips():
        receipts = list(trip.get("receipts") or [])
        items.append(
            {
                "id": trip.get("id"),
                "name": trip.get("name"),
                "startDate": trip.get("startDate"),
                "endDate": trip.get("endDate"),
                "hostName": trip.get("hostName"),
                "inviteCode": trip.get("inviteCode"),
                "participants": list(trip.get("participants") or []),
                "participantCount": len(list(trip.get("participants") or [])),
                "receiptCount": len(receipts),
                "totalKrw": round(sum(_receipt_amount_in_krw(r) for r in receipts)),
                "totalsByCurrency": _trip_totals_by_currency(trip),
                "coverImagePath": trip.get("coverImagePath"),
            }
        )
    return {"items": items}


@router.get("/admin/receipts")
async def admin_receipt_list(request: FastAPIRequest) -> dict:
    _require_admin(request)
    return {"items": _admin_receipts()}


@router.get("/admin/cards")
async def admin_cards(request: FastAPIRequest) -> dict:
    _require_admin(request)
    items = []
    for user_id, cards in CARD_PROFILES_BY_USER.items():
        user = USERS.get(user_id, {})
        for card in list(cards or []):
            item = deepcopy(card)
            item["userId"] = user_id
            item["userName"] = user.get("name")
            item["userDisplayName"] = _user_display_name(user)
            items.append(item)
    return {"items": sorted(items, key=lambda item: (str(item.get("userDisplayName") or item.get("userName") or ""), str(item.get("name") or "")))}


@router.get("/admin/media")
async def admin_media(request: FastAPIRequest) -> dict:
    _require_admin(request)
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT id, kind, original_name, content_type, public_path,
                       size_bytes, created_at
                FROM media_files
                ORDER BY created_at DESC
                LIMIT 500
                """
            ).fetchall()
    except sqlite3.Error:
        rows = []
    return {
        "items": [
            {
                "id": row[0],
                "kind": row[1],
                "originalName": row[2],
                "contentType": row[3],
                "publicPath": row[4],
                "sizeBytes": row[5],
                "createdAt": row[6],
            }
            for row in rows
        ]
    }


@router.get("/admin/exchange-rates")
async def admin_exchange_rates(request: FastAPIRequest) -> dict:
    _require_admin(request)
    try:
        with _DB_LOCK, _db_connect() as conn:
            rows = conn.execute(
                """
                SELECT currency_code, rate_date, krw_per_unit, as_of_label, source
                FROM exchange_rates
                ORDER BY rate_date DESC, currency_code
                LIMIT 500
                """
            ).fetchall()
    except sqlite3.Error:
        rows = []
    return {
        "items": [
            {
                "currencyCode": row[0],
                "rateDate": row[1],
                "krwPerUnit": row[2],
                "asOfLabel": row[3],
                "source": row[4],
            }
            for row in rows
        ]
    }


@router.get("/payment/fee-catalog")
async def payment_fee_catalog() -> dict:
    issuers = _fee_catalog_items_from_db("issuer") or _fee_catalog_items(
        CARD_ISSUER_FEE_RATES,
        source_urls=CARD_ISSUER_SOURCE_URLS,
    )
    brands = _fee_catalog_items_from_db("brand") or _fee_catalog_items(
        CARD_BRAND_FEE_RATES,
        default_source_url=CARD_BRAND_SOURCE_URL,
    )
    products = _card_products_from_db() or deepcopy(CARD_PRODUCT_CATALOG)
    return {
        "asOfLabel": EXCHANGE_RATE_AS_OF_LABEL,
        "issuers": issuers,
        "brands": brands,
        "products": products,
        "notes": [
            "대표 해외서비스 수수료 기준입니다.",
            "카드 타입이 체크이고 정책이 건당 수수료인 경우 issuerFeeType=fixed_usd로 계산합니다.",
            "트래블로그처럼 카드사 신용/체크 상품으로 발급되는 여행 특화 카드는 상품명 기반으로 수수료 면제 후보를 우선 처리합니다.",
            "카드 저장 후에는 카드명 기반 LLM 리서치가 백그라운드로 근거를 확인하고 상품별 수수료를 카드 프로필에 반영합니다.",
        ],
    }


@router.post("/payment/estimate")
async def estimate_payment(payload: dict) -> dict:
    return deepcopy(_estimate_receipt_payment(payload))


@router.post("/media/upload")
async def upload_media(
    request: FastAPIRequest,
    file: UploadFile = File(...),
    kind: str = Form("receipt"),
) -> dict:
    content_type = file.content_type or "application/octet-stream"
    if not content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image uploads are supported")

    max_bytes = 8 * 1024 * 1024
    content = await file.read(max_bytes + 1)
    if not content:
        raise HTTPException(status_code=400, detail="Empty upload")
    if len(content) > max_bytes:
        raise HTTPException(status_code=413, detail="Image is too large")
    _validate_image_bytes(content)

    media_kind = _media_kind(kind)
    filename = f"{uuid4().hex}{_media_extension(file)}"
    target = _media_path(media_kind, filename)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)

    public_path = _media_public_path(media_kind, filename)
    media_id = str(uuid4())
    created_at = datetime.now(timezone.utc).isoformat()
    with _DB_LOCK, _db_connect() as conn:
        conn.execute(
            """
            INSERT INTO media_files (
                id, kind, original_name, content_type, storage_path,
                public_path, size_bytes, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                media_id,
                media_kind,
                file.filename,
                content_type,
                str(target),
                public_path,
                len(content),
                created_at,
            ),
        )

    return {
        "id": media_id,
        "kind": media_kind,
        "url": _media_url(request, public_path),
        "path": public_path,
        "contentType": content_type,
        "sizeBytes": len(content),
        "createdAt": created_at,
    }


@router.post("/receipts/recognize")
async def recognize_receipt(payload: dict) -> dict:
    image_reference = _first_present(
        payload.get("imagePath"),
        payload.get("imageUrl"),
        payload.get("path"),
        payload.get("url"),
    )
    image_path, public_path = _media_reference_to_path(image_reference)
    currency_code = str(payload.get("currencyCode") or payload.get("currency") or "KRW")
    recognition_strategy = str(
        payload.get("recognitionStrategy")
        or payload.get("strategy")
        or payload.get("mode")
        or ""
    ).strip()
    response_image_reference = (
        str(image_reference).strip()
        if str(image_reference or "").strip().startswith(("http://", "https://"))
        else public_path
    )
    return await asyncio.to_thread(
        recognize_receipt_image,
        image_path=image_path,
        image_reference=response_image_reference,
        currency_code=currency_code,
        recognition_strategy=recognition_strategy or None,
    )


@router.post("/receipts/recognize/compare")
async def compare_receipt_recognition(payload: dict) -> dict:
    image_reference = _first_present(
        payload.get("imagePath"),
        payload.get("imageUrl"),
        payload.get("path"),
        payload.get("url"),
    )
    image_path, public_path = _media_reference_to_path(image_reference)
    currency_code = str(payload.get("currencyCode") or payload.get("currency") or "KRW")
    raw_strategies = payload.get("strategies") or ["hybrid", "cloud_gemini"]
    if not isinstance(raw_strategies, list):
        raise HTTPException(status_code=400, detail="strategies must be a list")
    strategies = [
        str(strategy).strip()
        for strategy in raw_strategies
        if str(strategy or "").strip()
    ][:4]
    if not strategies:
        raise HTTPException(status_code=400, detail="At least one recognition strategy is required")
    response_image_reference = (
        str(image_reference).strip()
        if str(image_reference or "").strip().startswith(("http://", "https://"))
        else public_path
    )

    items: list[dict] = []
    for strategy in strategies:
        try:
            result = await asyncio.to_thread(
                recognize_receipt_image,
                image_path=image_path,
                image_reference=response_image_reference,
                currency_code=currency_code,
                recognition_strategy=strategy,
            )
            items.append({"strategy": strategy, "ok": True, "result": result})
        except HTTPException as exc:
            items.append(
                {
                    "strategy": strategy,
                    "ok": False,
                    "statusCode": exc.status_code,
                    "error": exc.detail,
                }
            )
    return {
        "imagePath": response_image_reference,
        "currencyCode": currency_code,
        "items": items,
    }


@router.post("/receipts/recognize-text")
async def recognize_receipt_from_text(payload: dict) -> dict:
    ocr_text = str(payload.get("ocrText") or payload.get("text") or "").strip()
    if not ocr_text:
        raise HTTPException(status_code=400, detail="OCR text is required")
    currency_code = str(payload.get("currencyCode") or payload.get("currency") or "KRW")
    image_reference = payload.get("imagePath") or payload.get("imageUrl")
    return await asyncio.to_thread(
        recognize_receipt_text,
        ocr_text=ocr_text,
        currency_code=currency_code,
        image_reference=str(image_reference).strip() if image_reference else None,
    )


@router.get("/media/{kind}/{filename}")
async def get_media(kind: str, filename: str) -> FileResponse:
    if "/" in filename or "\\" in filename:
        raise HTTPException(status_code=404, detail="Media not found")
    target = _media_path(kind, filename)
    if not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="Media not found")
    media_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    return FileResponse(target, media_type=media_type)


def _find_user(name: str, phone_number: str) -> dict | None:
    normalized = _normalize_phone(phone_number)
    for user in USERS.values():
        if user["name"] == name and user["phoneNumber"] == normalized:
            return user
    return None


def _create_user(name: str, phone_number: str) -> dict:
    user_id = str(uuid4())
    user = {
        "id": user_id,
        "name": name,
        "nickname": "",
        "phoneNumber": _normalize_phone(phone_number),
        "accessToken": create_access_token(user_id),
    }
    USERS[user_id] = user
    TRIPS_BY_USER[user_id] = []
    CARD_PROFILES_BY_USER[user_id] = []
    _save_user(user)
    _save_trips_for_user(user_id)
    _save_cards_for_user(user_id)
    return user


def _find_user_by_kakao_id(kakao_id: str) -> dict | None:
    for candidate in USERS.values():
        if str(candidate.get("kakaoUserId") or "") == str(kakao_id):
            return candidate
    return None


def _create_user_from_kakao(profile: dict) -> dict:
    user_id = str(uuid4())
    kakao_id = str(profile.get("kakaoUserId") or "").strip()
    display = str(profile.get("name") or "").strip()[:80] or f"카카오{kakao_id}"
    user = {
        "id": user_id,
        "name": display,
        "nickname": "",
        "phoneNumber": _normalize_phone(str(profile.get("phoneNumber") or "")),
        "kakaoUserId": kakao_id,
        "accessToken": create_access_token(user_id),
    }
    USERS[user_id] = user
    TRIPS_BY_USER[user_id] = []
    CARD_PROFILES_BY_USER[user_id] = []
    _save_user(user)
    _save_trips_for_user(user_id)
    _save_cards_for_user(user_id)
    return user


def _new_invite_code() -> str:
    return str(uuid4()).replace("-", "")[:6].upper()


def _all_trips() -> list[dict]:
    trips: list[dict] = []
    seen: set[str] = set()
    for user_trips in TRIPS_BY_USER.values():
        for trip in user_trips:
            trip_id = str(trip.get("id") or "")
            if trip_id in seen:
                continue
            seen.add(trip_id)
            trips.append(trip)
    return trips


def _find_trip(trip_id: str) -> dict | None:
    for trip in _all_trips():
        if trip.get("id") == trip_id:
            return trip
    return None


def _is_host(user: dict, trip: dict) -> bool:
    if str(trip.get("hostUserId") or "") == str(user.get("id") or ""):
        return True
    return str(trip.get("hostName") or "").strip() in _user_name_aliases(user)


def _is_participant(user: dict, trip: dict) -> bool:
    aliases = _user_name_aliases(user)
    return any(str(name or "").strip() in aliases for name in list(trip.get("participants") or []))


def _is_user_named(user: dict, name: object) -> bool:
    return str(name or "").strip() in _user_name_aliases(user)


def _require_trip_member(user: dict, trip: dict) -> None:
    if not (_is_host(user, trip) or _is_participant(user, trip)):
        raise HTTPException(status_code=403, detail="Trip access denied")


def _require_trip_host(user: dict, trip: dict) -> None:
    if not _is_host(user, trip):
        raise HTTPException(status_code=403, detail="Trip owner only")


def _receipt_id(receipt: dict) -> str:
    return str(receipt.get("id") or "")


def _validate_member_trip_update(user: dict, current: dict, incoming: dict) -> None:
    for field in TRIP_ADMIN_FIELDS:
        if current.get(field) != incoming.get(field):
            raise HTTPException(status_code=403, detail="Trip owner only")

    user_names = _user_name_aliases(user)
    if "receipts" not in incoming:
        return

    current_receipts = {
        _receipt_id(receipt): receipt
        for receipt in list(current.get("receipts") or [])
        if _receipt_id(receipt)
    }
    incoming_receipts = {
        _receipt_id(receipt): receipt
        for receipt in list(incoming.get("receipts") or [])
        if _receipt_id(receipt)
    }

    for receipt_id, receipt in current_receipts.items():
        if receipt_id not in incoming_receipts and str(receipt.get("paidBy") or "").strip() not in user_names:
            raise HTTPException(
                status_code=403,
                detail="Only the payer can delete this receipt",
            )

    for receipt_id, receipt in incoming_receipts.items():
        original = current_receipts.get(receipt_id)
        if original is None:
            if str(receipt.get("paidBy") or "").strip() not in user_names:
                raise HTTPException(
                    status_code=403,
                    detail="Members can only create their own receipts",
                )
            continue

        if str(original.get("paidBy") or "").strip() not in user_names and original != receipt:
            raise HTTPException(
                status_code=403,
                detail="Only the payer can edit this receipt",
            )


def _replace_trip_everywhere(trip: dict) -> None:
    trip_id = trip.get("id")
    if not trip_id:
        return
    changed_user_ids: set[str] = set()
    for user_id, trips in TRIPS_BY_USER.items():
        for index, current in enumerate(trips):
            if current.get("id") == trip_id:
                TRIPS_BY_USER[user_id][index] = deepcopy(trip)
                changed_user_ids.add(user_id)
    for user_id in changed_user_ids:
        _save_trips_for_user(user_id)


def _sync_trip_after_receipt_change(trip: dict) -> None:
    trip_id = trip.get("id")
    if not trip_id:
        return
    changed_user_ids: set[str] = set()
    for user_id, trips in TRIPS_BY_USER.items():
        for current in trips:
            if current.get("id") != trip_id:
                continue
            current["receipts"] = deepcopy(trip.get("receipts") or [])
            changed_user_ids.add(user_id)
    for user_id in changed_user_ids:
        _save_trips_for_user(user_id)


def _remove_trip_for_user(user_id: str, trip_id: str) -> None:
    TRIPS_BY_USER[user_id] = [
        trip for trip in TRIPS_BY_USER.setdefault(user_id, []) if trip.get("id") != trip_id
    ]
    _save_trips_for_user(user_id)


def _delete_trip_everywhere(trip_id: str) -> None:
    for existing_user_id in list(TRIPS_BY_USER.keys()):
        _remove_trip_for_user(existing_user_id, trip_id)
    with _DB_LOCK, _db_connect() as conn:
        conn.execute("DELETE FROM trips WHERE id = ?", (trip_id,))


def _delete_user_account(user_id: str) -> bool:
    user = USERS.get(user_id)
    if user is None:
        return False

    aliases = _user_name_aliases(user)
    owned_trip_ids: set[str] = set()
    changed_trip_ids: set[str] = set()

    for trip in _all_trips():
        trip_id = str(trip.get("id") or "")
        if not trip_id:
            continue
        if _is_host(user, trip):
            owned_trip_ids.add(trip_id)
            continue
        if _is_participant(user, trip):
            next_participants = [
                name
                for name in list(trip.get("participants") or [])
                if str(name or "").strip() not in aliases
            ]
            if next_participants != list(trip.get("participants") or []):
                trip["participants"] = next_participants
                changed_trip_ids.add(trip_id)

    for trip_id in changed_trip_ids:
        trip = _find_trip(trip_id)
        if trip is not None:
            _replace_trip_everywhere(trip)

    for trip_id in owned_trip_ids:
        _delete_trip_everywhere(trip_id)

    USERS.pop(user_id, None)
    TRIPS_BY_USER.pop(user_id, None)
    CARD_PROFILES_BY_USER.pop(user_id, None)
    with _DB_LOCK, _db_connect() as conn:
        conn.execute("DELETE FROM card_profiles WHERE user_id = ?", (user_id,))
        conn.execute("DELETE FROM user_trips WHERE user_id = ?", (user_id,))
        conn.execute("DELETE FROM trip_participants WHERE user_id = ?", (user_id,))
        conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    return True


def _upsert_trip_for_user(user_id: str, trip: dict) -> None:
    trips = TRIPS_BY_USER.setdefault(user_id, [])
    for index, current in enumerate(trips):
        if current.get("id") == trip.get("id"):
            trips[index] = deepcopy(trip)
            _save_trips_for_user(user_id)
            return
    trips.insert(0, deepcopy(trip))
    _save_trips_for_user(user_id)


def _find_user_by_name(name: str) -> dict | None:
    return _find_user_by_participant_name(name)


def _replace_name_key(values: dict, old_names: set[str], new_name: str) -> dict:
    out: dict = {}
    for key, value in dict(values or {}).items():
        text = str(key or "").strip()
        target = new_name if text in old_names else text
        if not target:
            continue
        out[target] = _as_float(out.get(target), 0.0) + _as_float(value)
    return out


def _sync_user_display_name_everywhere(
    user: dict,
    old_names: set[str],
    new_name: str,
) -> None:
    user_id = str(user.get("id") or "")
    if not user_id or not new_name:
        return
    old_names = {name for name in old_names if name and name != new_name}
    if not old_names:
        return

    changed_trip_ids: set[str] = set()
    for trip in _all_trips():
        changed = False
        if str(trip.get("hostUserId") or "") == user_id or str(trip.get("hostName") or "").strip() in old_names:
            trip["hostName"] = new_name
            trip["hostUserId"] = user_id
            changed = True

        participants = []
        for name in list(trip.get("participants") or []):
            text = str(name or "").strip()
            participants.append(new_name if text in old_names else text)
        normalized_participants = _dedupe_names(participants)
        if normalized_participants != list(trip.get("participants") or []):
            trip["participants"] = normalized_participants
            changed = True

        for receipt in list(trip.get("receipts") or []):
            if str(receipt.get("paidBy") or "").strip() in old_names:
                receipt["paidBy"] = new_name
                changed = True
            for item in list(receipt.get("items") or []):
                split_map = item.get("quantityByPerson") or {}
                if isinstance(split_map, dict) and old_names.intersection(
                    {str(key or "").strip() for key in split_map.keys()}
                ):
                    item["quantityByPerson"] = _replace_name_key(
                        split_map,
                        old_names,
                        new_name,
                    )
                    changed = True

        if changed and trip.get("id"):
            changed_trip_ids.add(str(trip["id"]))

    for trip_id in changed_trip_ids:
        trip = _find_trip(trip_id)
        if trip is not None:
            _replace_trip_everywhere(trip)


def _repair_trip_display_names_from_users() -> None:
    for user in list(USERS.values()):
        display = _user_display_name(user)
        canonical = str(user.get("name") or "").strip()
        nickname = str(user.get("nickname") or "").strip()
        if display and nickname and canonical and display != canonical:
            _sync_user_display_name_everywhere(user, {canonical}, display)
    for trip in _all_trips():
        _replace_trip_everywhere(trip)


_load_db_state()
_repair_trip_display_names_from_users()


@router.post("/auth/kakao")
async def auth_kakao(payload: dict) -> dict:
    raw = str(payload.get("accessToken") or payload.get("access_token") or "").strip()
    if not raw:
        raise HTTPException(status_code=400, detail="accessToken is required")
    profile = await fetch_kakao_profile(raw)
    if profile is None:
        raise HTTPException(status_code=401, detail="Invalid Kakao access token")
    kakao_id = str(profile.get("kakaoUserId") or "").strip()
    if not kakao_id:
        raise HTTPException(status_code=401, detail="Invalid Kakao profile")
    user = _find_user_by_kakao_id(kakao_id)
    if user is None:
        user = _create_user_from_kakao(profile)
    else:
        profile_name = str(profile.get("name") or "").strip()
        profile_phone = _normalize_phone(str(profile.get("phoneNumber") or ""))
        if profile_name and not str(user.get("name") or "").strip():
            user["name"] = profile_name
        if profile_phone and not str(user.get("phoneNumber") or "").strip():
            user["phoneNumber"] = profile_phone
        user["accessToken"] = create_access_token(user["id"])
        _save_user(user)
    return _public_user(user)


@router.get("/me")
async def current_user(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Authorization bearer token required")
    token = authorization[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Authorization bearer token required")

    try:
        user_id = decode_access_token_subject(token)
    except (JWTError, ValueError):
        raise HTTPException(status_code=401, detail="Invalid or expired token") from None

    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    user["accessToken"] = create_access_token(user["id"])
    _save_user(user)
    return _public_user(user)


@router.get("/users/lookup")
async def lookup_user(name: str, phoneNumber: str) -> dict:
    if not settings.enable_legacy_auth:
        raise HTTPException(status_code=403, detail="Use Kakao login; legacy login is disabled")
    user = _find_user(name, phoneNumber)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    user["accessToken"] = create_access_token(user["id"])
    _save_user(user)
    return _public_user(user)


@router.post("/users", status_code=status.HTTP_201_CREATED)
async def create_user(payload: dict) -> dict:
    if not settings.enable_legacy_auth:
        raise HTTPException(status_code=403, detail="Use Kakao login; legacy login is disabled")
    name = str(payload.get("name") or "").strip()
    phone_number = str(payload.get("phoneNumber") or payload.get("phone_number") or "")
    if not name or not _normalize_phone(phone_number):
        raise HTTPException(status_code=400, detail="Name and phoneNumber are required")
    existing = _find_user(name, phone_number)
    if existing is not None:
        existing["accessToken"] = create_access_token(existing["id"])
        _save_user(existing)
        return _public_user(existing)
    return _public_user(_create_user(name, phone_number))


@router.patch("/users/{user_id}")
async def update_user(user_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    old_names = _user_name_aliases(user)
    user["name"] = str(payload.get("name") or user["name"]).strip()
    if "nickname" in payload:
        user["nickname"] = str(payload.get("nickname") or "").strip()
    user["phoneNumber"] = _normalize_phone(
        str(payload.get("phoneNumber") or user["phoneNumber"])
    )
    if "settlementBankName" in payload or "settlement_bank_name" in payload:
        user["settlementBankName"] = str(
            payload.get("settlementBankName", payload.get("settlement_bank_name")) or ""
        ).strip()
    if "settlementAccountNumber" in payload or "settlement_account_number" in payload:
        user["settlementAccountNumber"] = str(
            payload.get(
                "settlementAccountNumber",
                payload.get("settlement_account_number"),
            )
            or ""
        ).strip()
    if "settlementAccountHolder" in payload or "settlement_account_holder" in payload:
        user["settlementAccountHolder"] = str(
            payload.get(
                "settlementAccountHolder",
                payload.get("settlement_account_holder"),
            )
            or ""
        ).strip()
    _save_user(user)
    _sync_user_display_name_everywhere(user, old_names, _user_display_name(user))
    return _public_user(user)


@router.delete("/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_user(user_id: str) -> Response:
    if not _delete_user_account(user_id):
        raise HTTPException(status_code=404, detail="User not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/users/{user_id}/cards")
async def list_cards(user_id: str) -> dict:
    if user_id not in USERS:
        raise HTTPException(status_code=404, detail="User not found")
    return {"items": deepcopy(CARD_PROFILES_BY_USER.setdefault(user_id, []))}


@router.put("/users/{user_id}/cards")
async def save_cards(user_id: str, payload: dict) -> dict:
    if user_id not in USERS:
        raise HTTPException(status_code=404, detail="User not found")

    raw = payload.get("items") if isinstance(payload, dict) else None
    if raw is None and isinstance(payload, list):
        raw = payload
    if not isinstance(raw, list):
        raise HTTPException(status_code=400, detail="items list is required")

    cards: list[dict] = []
    used_card_ids: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        card = deepcopy(item)
        card["id"] = str(card.get("id") or uuid4())
        if card["id"] in used_card_ids or any(
            other_user_id != user_id
            and any(existing.get("id") == card["id"] for existing in other_cards)
            for other_user_id, other_cards in CARD_PROFILES_BY_USER.items()
        ):
            card["id"] = str(uuid4())
        used_card_ids.add(card["id"])
        card = _merge_existing_card_research(user_id, card)
        card.update(_card_fee_policy_for(card))
        if settings.card_fee_research_enabled and card.get("feeResearchStatus") in {"idle", "failed"}:
            card["feeResearchStatus"] = "pending"
        cards.append(card)
    CARD_PROFILES_BY_USER[user_id] = cards
    _save_cards_for_user(user_id)
    for card in cards:
        if card.get("feeResearchStatus") == "pending":
            _maybe_schedule_card_fee_research(user_id, str(card.get("id")))
    return {"items": deepcopy(cards)}


@router.post("/users/{user_id}/cards", status_code=status.HTTP_201_CREATED)
async def create_card(user_id: str, payload: dict) -> dict:
    if user_id not in USERS:
        raise HTTPException(status_code=404, detail="User not found")
    raw = payload.get("item") if isinstance(payload, dict) and isinstance(payload.get("item"), dict) else payload
    if not isinstance(raw, dict):
        raise HTTPException(status_code=400, detail="card item is required")

    card = deepcopy(raw)
    card["id"] = str(card.get("id") or uuid4())
    existing_ids = {
        str(existing.get("id"))
        for cards in CARD_PROFILES_BY_USER.values()
        for existing in cards
        if existing.get("id")
    }
    if card["id"] in existing_ids:
        card["id"] = str(uuid4())
    card = _card_with_research_defaults(card)
    card.update(_card_fee_policy_for(card))
    if settings.card_fee_research_enabled:
        card["feeResearchStatus"] = "pending"
    CARD_PROFILES_BY_USER.setdefault(user_id, []).append(card)
    _save_cards_for_user(user_id)
    _maybe_schedule_card_fee_research(user_id, str(card.get("id")))
    return deepcopy(card)


@router.get("/users/{user_id}/trips")
async def list_trips(user_id: str) -> dict:
    if user_id not in USERS:
        return {"items": []}
    return {"items": deepcopy(TRIPS_BY_USER.setdefault(user_id, []))}


@router.get("/users/{user_id}/trips/{trip_id}/cards")
async def list_trip_participant_cards(user_id: str, trip_id: str, participantName: str) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)

    participant_name = participantName.strip()
    participant = _find_user_by_participant_name(participant_name)
    participant_aliases = _user_name_aliases(participant) if participant else {participant_name}
    if not any(
        str(name or "").strip() in participant_aliases
        for name in list(trip.get("participants") or [])
    ):
        raise HTTPException(status_code=404, detail="Participant not found")
    if not _is_host(user, trip) and not participant_aliases.intersection(_user_name_aliases(user)):
        raise HTTPException(status_code=403, detail="Card owner only")

    if participant is None:
        return {"items": []}
    return {"items": deepcopy(CARD_PROFILES_BY_USER.setdefault(participant["id"], []))}


@router.post("/users/{user_id}/trips", status_code=status.HTTP_201_CREATED)
async def create_trip(user_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    trip = deepcopy(payload)
    user_display_name = _user_display_name(user)
    trip["id"] = str(trip.get("id") or uuid4())
    trip.setdefault("receipts", [])
    trip.setdefault("participants", [user_display_name])
    trip["participants"] = _dedupe_names(
        [
            user_display_name if str(name or "").strip() in _user_name_aliases(user) else str(name or "").strip()
            for name in list(trip.get("participants") or [])
        ]
    )
    if user_display_name not in trip["participants"]:
        trip["participants"].insert(0, user_display_name)
    trip["hostName"] = user_display_name
    trip["hostUserId"] = user["id"]
    trip.setdefault("inviteCode", _new_invite_code())
    trip = _normalize_trip_receipts(trip)
    _upsert_trip_for_user(user_id, trip)
    return deepcopy(trip)


@router.post("/users/{user_id}/trips/join")
async def join_trip(user_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    invite_code = str(payload.get("inviteCode") or payload.get("invite_code") or "").upper()
    if not invite_code:
        raise HTTPException(status_code=400, detail="inviteCode is required")

    for trip in _all_trips():
        if str(trip.get("inviteCode") or "").upper() != invite_code:
            continue
        participants = list(trip.get("participants") or [])
        user_display_name = _user_display_name(user)
        if not any(str(name or "").strip() in _user_name_aliases(user) for name in participants):
            participants.append(user_display_name)
            trip["participants"] = participants
            _replace_trip_everywhere(trip)
        _upsert_trip_for_user(user_id, trip)
        return deepcopy(trip)

    raise HTTPException(status_code=404, detail="Trip not found")


@router.put("/users/{user_id}/trips/{trip_id}")
async def update_trip(user_id: str, trip_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    current = _find_trip(trip_id)
    if current is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, current)

    trip = deepcopy(payload)
    trip["id"] = trip_id
    trip.setdefault("inviteCode", current.get("inviteCode") or _new_invite_code())
    trip.setdefault("hostName", current.get("hostName"))

    if not _is_host(user, current):
        _validate_member_trip_update(user, current, trip)
    elif trip.get("hostName") != current.get("hostName"):
        raise HTTPException(status_code=403, detail="Trip owner cannot be changed")

    if "receipts" not in trip:
        trip["receipts"] = deepcopy(current.get("receipts") or [])
    trip = _normalize_trip_receipts(trip)
    _replace_trip_everywhere(trip)
    return deepcopy(trip)


@router.post("/users/{user_id}/trips/{trip_id}/leave", status_code=status.HTTP_204_NO_CONTENT)
async def leave_trip(user_id: str, trip_id: str) -> Response:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    target: dict | None = None
    for trip in _all_trips():
        if trip.get("id") == trip_id:
            target = trip
            break

    if target is None:
        _remove_trip_for_user(user_id, trip_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    if _is_host(user, target):
        raise HTTPException(status_code=403, detail="Trip owner cannot leave")

    aliases = _user_name_aliases(user)
    target["participants"] = [
        name
        for name in list(target.get("participants") or [])
        if str(name or "").strip() not in aliases
    ]
    _replace_trip_everywhere(target)
    _remove_trip_for_user(user_id, trip_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/users/{user_id}/trips/{trip_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_trip(user_id: str, trip_id: str) -> Response:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    _require_trip_host(user, trip)
    _delete_trip_everywhere(trip_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/users/{user_id}/trips/{trip_id}/receipts")
async def list_receipts(user_id: str, trip_id: str) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        return {"items": []}
    _require_trip_member(user, trip)
    normalized = [_estimate_receipt_payment(r) for r in list(trip.get("receipts") or [])]
    return {"items": deepcopy(normalized)}


@router.get("/users/{user_id}/trips/{trip_id}/settlement")
async def get_settlement(user_id: str, trip_id: str) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)
    return deepcopy(_settlement_summary(trip))


@router.put("/users/{user_id}/trips/{trip_id}/settlement/status")
async def update_settlement_transfer_status(user_id: str, trip_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)

    mode, from_name, to_name = _settlement_transfer_status_key(
        payload.get("mode"),
        payload.get("from"),
        payload.get("to"),
    )
    if not from_name or not to_name:
        raise HTTPException(status_code=400, detail="Settlement transfer participants required")
    completed = bool(payload.get("completed"))
    return _save_settlement_transfer_status(
        trip_id=trip_id,
        mode=mode,
        from_name=from_name,
        to_name=to_name,
        completed=completed,
        updated_by_user_id=user_id,
    )


@router.post("/users/{user_id}/trips/{trip_id}/receipts", status_code=status.HTTP_201_CREATED)
async def create_receipt(user_id: str, trip_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)

    receipt = _estimate_receipt_payment(payload)
    receipt["id"] = str(receipt.get("id") or uuid4())
    if not _is_host(user, trip) and not _is_user_named(user, receipt.get("paidBy")):
        raise HTTPException(status_code=403, detail="Members can only create their own receipts")

    receipts = list(trip.get("receipts") or [])
    index = next(
        (i for i, current in enumerate(receipts) if _receipt_id(current) == receipt["id"]),
        -1,
    )
    if index >= 0:
        original = receipts[index]
        if not _is_host(user, trip) and not _is_user_named(user, original.get("paidBy")):
            raise HTTPException(status_code=403, detail="Only the payer can edit this receipt")
        receipts[index] = receipt
    else:
        receipts.append(receipt)
    trip["receipts"] = receipts
    _sync_trip_after_receipt_change(trip)
    return deepcopy(receipt)


@router.put("/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}")
async def update_receipt(user_id: str, trip_id: str, receipt_id: str, payload: dict) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)

    receipts = list(trip.get("receipts") or [])
    index = next(
        (i for i, current in enumerate(receipts) if _receipt_id(current) == receipt_id),
        -1,
    )

    receipt = _estimate_receipt_payment(payload)
    receipt["id"] = receipt_id
    if index < 0:
        if not _is_host(user, trip) and not _is_user_named(user, receipt.get("paidBy")):
            raise HTTPException(
                status_code=403,
                detail="Members can only create their own receipts",
            )
        receipts.append(receipt)
        trip["receipts"] = receipts
        _sync_trip_after_receipt_change(trip)
        return deepcopy(receipt)

    original = receipts[index]
    is_host = _is_host(user, trip)
    is_payer = _is_user_named(user, original.get("paidBy"))
    if not is_host and not is_payer:
        if not _receipt_payment_fields_equal(original, receipt):
            raise HTTPException(
                status_code=403,
                detail="Only the payer or trip owner can edit payment details",
            )
        merged = deepcopy(original)
        merged["items"] = deepcopy(receipt.get("items") or [])
        receipt = _estimate_receipt_payment(merged)
        receipt["id"] = receipt_id
    elif not is_host and not _is_user_named(user, receipt.get("paidBy")):
        raise HTTPException(status_code=403, detail="Members can only keep their own receipt payer")

    if index >= 0:
        receipts[index] = receipt
    trip["receipts"] = receipts
    _sync_trip_after_receipt_change(trip)
    return deepcopy(receipt)


@router.put("/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}/items/{item_index}")
async def upsert_receipt_item(
    user_id: str,
    trip_id: str,
    receipt_id: str,
    item_index: int,
    payload: dict,
) -> dict:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    _require_trip_member(user, trip)
    if item_index < 0:
        raise HTTPException(status_code=400, detail="item_index must be non-negative")

    receipts = list(trip.get("receipts") or [])
    receipt_index = next(
        (i for i, current in enumerate(receipts) if _receipt_id(current) == receipt_id),
        -1,
    )
    if receipt_index < 0:
        raise HTTPException(status_code=404, detail="Receipt not found")

    receipt = deepcopy(receipts[receipt_index])

    items = list(receipt.get("items") or [])
    if item_index > len(items):
        raise HTTPException(status_code=400, detail="Items must be uploaded in order")
    item = deepcopy(payload)
    if item_index == len(items):
        items.append(item)
    else:
        items[item_index] = item
    receipt["items"] = items
    receipts[receipt_index] = _estimate_receipt_payment(receipt)
    trip["receipts"] = receipts
    _sync_trip_after_receipt_change(trip)
    return deepcopy(receipts[receipt_index])


@router.delete("/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_receipt(user_id: str, trip_id: str, receipt_id: str) -> Response:
    user = USERS.get(user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    trip = _find_trip(trip_id)
    if trip is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    _require_trip_member(user, trip)

    receipts = list(trip.get("receipts") or [])
    target = next((receipt for receipt in receipts if _receipt_id(receipt) == receipt_id), None)
    if target is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    if not _is_host(user, trip) and not _is_user_named(user, target.get("paidBy")):
        raise HTTPException(status_code=403, detail="Only the payer can delete this receipt")
    trip["receipts"] = [receipt for receipt in receipts if _receipt_id(receipt) != receipt_id]
    _sync_trip_after_receipt_change(trip)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

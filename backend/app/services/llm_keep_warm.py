from __future__ import annotations

import asyncio
from contextlib import suppress

import httpx

from app.core.config import settings


async def keep_receipt_llm_warm() -> None:
    if not settings.receipt_llm_keep_warm_enabled:
        return

    interval = max(60, int(settings.receipt_llm_keep_warm_interval_seconds or 900))
    await asyncio.sleep(10)
    while True:
        await _warm_once()
        await asyncio.sleep(interval)


async def _warm_once() -> None:
    url = settings.receipt_llm_base_url.rstrip("/") or "http://ollama:11434"
    payload: dict[str, object] = {
        "model": settings.receipt_llm_model,
        "stream": False,
        "format": "json",
        "messages": [
            {
                "role": "user",
                "content": 'Return exactly {"ok":true} as JSON.',
            }
        ],
        "options": {
            "temperature": 0,
            "num_ctx": max(int(settings.receipt_llm_num_ctx or 8192), 8192),
            "num_predict": 16,
        },
    }
    keep_alive = settings.receipt_llm_keep_alive.strip()
    if keep_alive:
        payload["keep_alive"] = keep_alive

    with suppress(Exception):
        async with httpx.AsyncClient(timeout=60) as client:
            await client.post(f"{url}/api/chat", json=payload)

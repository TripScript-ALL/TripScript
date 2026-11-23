from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import sys
import time
from typing import Any

import cv2
import httpx
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.config import settings
from app.services.receipt_recognition import (
    _json_object_from_text,
    _vision_llm_system_prompt,
    _vision_llm_user_prompt,
)


def _resize_image(raw: bytes, edge: int) -> tuple[bytes, str]:
    source = np.frombuffer(raw, dtype=np.uint8)
    image = cv2.imdecode(source, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("OpenCV could not decode image")

    height, width = image.shape[:2]
    scale = edge / float(max(width, height))
    resized_width = max(28, int(round(width * scale / 28)) * 28)
    resized_height = max(28, int(round(height * scale / 28)) * 28)
    resized = cv2.resize(
        image,
        (resized_width, resized_height),
        interpolation=cv2.INTER_AREA,
    )
    ok, encoded = cv2.imencode(
        ".jpg",
        resized,
        [int(cv2.IMWRITE_JPEG_QUALITY), int(settings.receipt_llm_image_jpeg_quality)],
    )
    if not ok:
        raise ValueError("OpenCV could not encode image")
    return encoded.tobytes(), f"{resized_width}x{resized_height}"


def _variant(raw: bytes, edge: str) -> tuple[bytes, str]:
    if edge == "raw":
        return raw, "raw"
    return _resize_image(raw, int(edge))


def _recognize(raw: bytes, currency: str) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": settings.receipt_llm_model,
        "stream": False,
        "format": "json",
        "messages": [
            {"role": "system", "content": _vision_llm_system_prompt()},
            {
                "role": "user",
                "content": _vision_llm_user_prompt(currency),
                "images": [base64.b64encode(raw).decode("ascii")],
            },
        ],
        "options": {
            "temperature": 0,
            "num_ctx": max(int(settings.receipt_llm_num_ctx or 8192), 8192),
            "num_predict": settings.receipt_llm_num_predict,
        },
        "keep_alive": settings.receipt_llm_keep_alive,
    }
    started = time.perf_counter()
    response = httpx.post(
        f"{settings.receipt_llm_base_url.rstrip('/')}/api/chat",
        json=payload,
        timeout=settings.receipt_recognition_timeout_seconds,
    )
    elapsed = round(time.perf_counter() - started, 2)
    if response.status_code != 200:
        return {
            "status": response.status_code,
            "elapsedSeconds": elapsed,
            "error": response.text[:400],
        }

    content = response.json()["message"]["content"]
    try:
        parsed = _json_object_from_text(content)
    except Exception as exc:
        return {
            "status": 200,
            "elapsedSeconds": elapsed,
            "parseError": str(exc),
            "content": content[:400],
        }

    return {
        "status": 200,
        "elapsedSeconds": elapsed,
        "storeName": parsed.get("storeName"),
        "amount": parsed.get("amount"),
        "date": parsed.get("date"),
        "currencyCode": parsed.get("currencyCode"),
        "itemCount": len(parsed.get("items") or []),
        "confidence": parsed.get("confidence"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("images", nargs="+", help="Receipt image paths inside the container")
    parser.add_argument("--currency", default="KRW")
    parser.add_argument("--edges", default="raw,1600,1344,1120,896")
    args = parser.parse_args()

    edges = [edge.strip() for edge in args.edges.split(",") if edge.strip()]
    for image in args.images:
        raw = Path(image).read_bytes()
        for edge in edges:
            data, dimensions = _variant(raw, edge)
            result = _recognize(data, args.currency)
            print(
                json.dumps(
                    {
                        "image": image,
                        "variant": edge,
                        "dimensions": dimensions,
                        "bytes": len(data),
                        **result,
                    },
                    ensure_ascii=False,
                ),
                flush=True,
            )


if __name__ == "__main__":
    main()

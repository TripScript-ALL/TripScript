from __future__ import annotations

import base64
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import logging
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from typing import Any
from uuid import uuid4

import httpx
from fastapi import HTTPException

from app.core.config import settings

logger = logging.getLogger("uvicorn.error")

_CLOUD_RECEIPT_CACHE_MAX = 128
_CLOUD_RECEIPT_CACHE: dict[str, dict[str, Any]] = {}
_CLOUD_RECEIPT_CACHE_ORDER: list[str] = []
_CLOUD_RECEIPT_CACHE_LOCK = threading.Lock()


@dataclass(frozen=True)
class RecognitionContext:
    image_path: Path | None
    image_reference: str | None
    currency_code: str
    ocr_preprocess: str = "safe"
    vision_preprocess: str = "safe"


@dataclass(frozen=True)
class OcrResult:
    text: str
    metadata: dict[str, Any]


def recognize_receipt_image(
    image_path: Path,
    image_reference: str,
    currency_code: str = "KRW",
    recognition_strategy: str | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    strategy = (recognition_strategy or settings.receipt_recognition_strategy).strip().lower()
    context = RecognitionContext(
        image_path=image_path,
        image_reference=image_reference,
        currency_code=_normalize_currency(currency_code),
        ocr_preprocess=_ocr_preprocess_for_strategy(strategy),
        vision_preprocess=_vision_preprocess_for_strategy(strategy),
    )
    if _is_cloud_image_strategy(strategy):
        return _recognize_receipt_image_cloud(context, started, strategy)

    if strategy in {"hybrid", "fast_ocr", "easyocr_hybrid", "ocr_llm", "hybrid_flatten", "ocr_llm_flatten"}:
        return _recognize_receipt_image_hybrid(context, started)

    if _uses_direct_image_llm():
        try:
            parsed = _parse_image_with_llm(context)
        except HTTPException:
            if not settings.receipt_vision_fallback_ocr_enabled:
                raise
            ocr_result = _run_ocr(context)
            return _with_recognition_duration(
                recognize_receipt_text(
                    ocr_text=ocr_result.text,
                    currency_code=context.currency_code,
                    image_reference=image_reference,
                    recognition_metadata={
                        **ocr_result.metadata,
                        "fallbackFrom": settings.receipt_llm_provider,
                    },
                ),
                started,
            )
        parsed["imagePath"] = image_reference
        parsed.setdefault("warnings", [])
        parsed.setdefault("recognition", {})
        parsed["recognition"].update(
            {
                "ocrProvider": "llm_vision",
                "llmProvider": settings.receipt_llm_provider,
                "llmModel": settings.receipt_llm_model,
                "recognizedAt": datetime.now(timezone.utc).isoformat(),
                "recognitionStrategy": "vision",
                "visionPreprocess": context.vision_preprocess,
            }
        )
        return _with_recognition_duration(
            _normalize_receipt_payload(parsed, context.currency_code),
            started,
        )

    ocr_result = _run_ocr(context)
    return _with_recognition_duration(
        recognize_receipt_text(
            ocr_text=ocr_result.text,
            currency_code=context.currency_code,
            image_reference=image_reference,
            recognition_metadata=ocr_result.metadata,
        ),
        started,
    )


def _ocr_preprocess_for_strategy(strategy: str) -> str:
    if "flatten" in strategy or "scan" in strategy:
        return "flatten"
    return "safe"


def _vision_preprocess_for_strategy(strategy: str) -> str:
    if "cloud" in strategy or "gemini" in strategy:
        return "flatten" if settings.receipt_cloud_llm_flatten_enabled else "safe"
    if "flatten" in strategy or "scan" in strategy:
        return "flatten"
    if "original" in strategy or "raw" in strategy:
        return "original"
    return "safe"


def _is_cloud_image_strategy(strategy: str) -> bool:
    return strategy in {
        "cloud",
        "cloud_vision",
        "cloud_gemini",
        "gemini",
        "gemini_vision",
        "gemini_flash",
    }


def _recognize_receipt_image_cloud(
    context: RecognitionContext,
    started: float,
    strategy: str,
) -> dict[str, Any]:
    if strategy not in {"cloud", "cloud_vision", "cloud_gemini", "gemini", "gemini_vision", "gemini_flash"}:
        raise HTTPException(status_code=503, detail=f"Unsupported cloud receipt strategy: {strategy}")

    cache_key = _cloud_receipt_cache_key(context)
    cached = _cloud_receipt_cache_get(cache_key)
    if cached is not None:
        parsed = cached
        parsed.setdefault("recognition", {})
        parsed["recognition"]["cacheHit"] = True
    else:
        parsed = _parse_image_with_gemini(context)
        _cloud_receipt_cache_set(cache_key, parsed)
    parsed["imagePath"] = context.image_reference
    parsed.setdefault("warnings", [])
    parsed.setdefault("recognition", {})
    parsed["recognition"].update(
        {
            "ocrProvider": "cloud_vision_llm",
            "llmProvider": "gemini",
            "llmModel": settings.receipt_gemini_model,
            "recognizedAt": datetime.now(timezone.utc).isoformat(),
            "recognitionStrategy": "cloud_gemini",
            "visionPreprocess": context.vision_preprocess,
        }
    )
    return _with_recognition_duration(
        _normalize_receipt_payload(parsed, context.currency_code),
        started,
    )


def _cloud_receipt_cache_key(context: RecognitionContext) -> str:
    if context.image_path is None or not context.image_path.exists():
        return ""
    digest = hashlib.sha256(context.image_path.read_bytes()).hexdigest()
    return "|".join(
        [
            settings.receipt_gemini_model.strip() or "gemini-2.5-flash",
            context.currency_code,
            context.vision_preprocess,
            str(settings.receipt_cloud_llm_flatten_enabled),
            str(settings.receipt_cloud_llm_image_max_edge),
            str(settings.receipt_cloud_llm_image_jpeg_quality),
            digest,
        ]
    )


def _cloud_receipt_cache_get(cache_key: str) -> dict[str, Any] | None:
    if not cache_key:
        return None
    with _CLOUD_RECEIPT_CACHE_LOCK:
        cached = _CLOUD_RECEIPT_CACHE.get(cache_key)
        return deepcopy(cached) if cached is not None else None


def _cloud_receipt_cache_set(cache_key: str, value: dict[str, Any]) -> None:
    if not cache_key:
        return
    with _CLOUD_RECEIPT_CACHE_LOCK:
        if cache_key in _CLOUD_RECEIPT_CACHE_ORDER:
            _CLOUD_RECEIPT_CACHE_ORDER.remove(cache_key)
        _CLOUD_RECEIPT_CACHE[cache_key] = deepcopy(value)
        _CLOUD_RECEIPT_CACHE_ORDER.append(cache_key)
        while len(_CLOUD_RECEIPT_CACHE_ORDER) > _CLOUD_RECEIPT_CACHE_MAX:
            old_key = _CLOUD_RECEIPT_CACHE_ORDER.pop(0)
            _CLOUD_RECEIPT_CACHE.pop(old_key, None)


def _recognize_receipt_image_hybrid(
    context: RecognitionContext,
    started: float,
) -> dict[str, Any]:
    fast_error: str | None = None
    fast_candidate: dict[str, Any] | None = None
    try:
        ocr_result = _run_ocr(context)
        fast = recognize_receipt_text(
            ocr_text=ocr_result.text,
            currency_code=context.currency_code,
            image_reference=context.image_reference,
            recognition_metadata={
                **ocr_result.metadata,
                "recognitionStrategy": "hybrid_ocr_text_llm",
            },
        )
        fast_candidate = fast
        if not _fast_ocr_needs_vision_fallback(fast, ocr_result.text, context.currency_code):
            fast.setdefault("recognition", {})
            fast["recognition"]["ocrTextLlmAccepted"] = True
            return _with_recognition_duration(fast, started)
        fast_error = "fast OCR result failed confidence checks"
    except HTTPException as exc:
        fast_error = str(exc.detail)

    if fast_candidate is not None and not settings.receipt_hybrid_vision_fallback_enabled:
        fast_candidate.setdefault("warnings", [])
        fast_candidate["warnings"].append(
            "OCR/텍스트 구조화 결과가 불안정할 수 있어 저장 전에 내용을 확인하세요."
        )
        fast_candidate.setdefault("recognition", {})
        fast_candidate["recognition"].update(
            {
                "recognitionStrategy": "hybrid_ocr_text_review",
                "fastFallbackReason": fast_error,
                "visionFallbackSkipped": True,
            }
        )
        return _with_recognition_duration(
            _normalize_receipt_payload(fast_candidate, context.currency_code),
            started,
        )

    try:
        parsed = _parse_image_with_llm(context)
    except HTTPException as exc:
        if fast_candidate is None:
            raise
        fast_candidate.setdefault("warnings", [])
        fast_candidate["warnings"].append(
            "Vision 보정에 실패해 빠른 OCR 결과를 사용했습니다. 저장 전에 내용을 확인하세요."
        )
        fast_candidate.setdefault("recognition", {})
        fast_candidate["recognition"].update(
            {
                "recognitionStrategy": "hybrid_fast_ocr_fallback",
                "visionFallbackError": str(exc.detail),
                "fastFallbackReason": fast_error,
            }
        )
        return _with_recognition_duration(
            _normalize_receipt_payload(fast_candidate, context.currency_code),
            started,
        )
    parsed["imagePath"] = context.image_reference
    parsed.setdefault("warnings", [])
    parsed.setdefault("recognition", {})
    parsed["recognition"].update(
        {
            "ocrProvider": "llm_vision",
            "llmProvider": settings.receipt_llm_provider,
            "llmModel": settings.receipt_llm_model,
            "recognizedAt": datetime.now(timezone.utc).isoformat(),
            "recognitionStrategy": "hybrid_vision_fallback",
            "visionPreprocess": context.vision_preprocess,
            "fastFallbackReason": fast_error,
        }
    )
    return _with_recognition_duration(
        _normalize_receipt_payload(parsed, context.currency_code),
        started,
    )


def _uses_direct_image_llm() -> bool:
    provider = settings.receipt_llm_provider.strip().lower()
    return provider in {"ollama_vision", "ollama_image", "ollama_multimodal"}


def _parse_image_with_llm(context: RecognitionContext) -> dict[str, Any]:
    if context.image_path is None or not context.image_path.exists():
        raise HTTPException(status_code=404, detail="Receipt image not found")
    provider = settings.receipt_llm_provider.strip().lower()
    if provider in {"ollama_vision", "ollama_image", "ollama_multimodal"}:
        return _parse_image_with_ollama(context)
    raise HTTPException(
        status_code=503,
        detail=f"Unsupported image LLM provider: {settings.receipt_llm_provider}",
    )


def _parse_image_with_gemini(context: RecognitionContext) -> dict[str, Any]:
    if context.image_path is None or not context.image_path.exists():
        raise HTTPException(status_code=404, detail="Receipt image not found")
    parsed = _gemini_generate_receipt_json(
        context,
        _cloud_vision_user_prompt(context.currency_code),
        pipeline="cloud_vision_single_pass",
    )
    if _cloud_receipt_needs_discount_repair(parsed, context.currency_code):
        repaired = _gemini_generate_receipt_json(
            context,
            _cloud_discount_repair_prompt(parsed, context.currency_code),
            pipeline="cloud_vision_discount_repair",
        )
        repaired.setdefault("recognition", {})
        repaired["recognition"]["discountRepairApplied"] = True
        return _best_receipt_candidate(parsed, repaired)
    return parsed


def _gemini_generate_receipt_json(
    context: RecognitionContext,
    prompt: str,
    *,
    pipeline: str,
) -> dict[str, Any]:
    api_key = settings.receipt_gemini_api_key.strip()
    if not api_key:
        raise HTTPException(status_code=503, detail="RECEIPT_GEMINI_API_KEY is not configured")
    model = settings.receipt_gemini_model.strip() or "gemini-2.5-flash"
    base_url = settings.receipt_gemini_base_url.rstrip("/") or "https://generativelanguage.googleapis.com/v1beta"
    image_b64, image_bytes = _cloud_vision_image_base64(context)
    prompt = prompt.strip() or _cloud_vision_user_prompt(context.currency_code)
    payload = {
        "contents": [
            {
                "parts": [
                    {"text": f"{_vision_llm_system_prompt()}\n\n{prompt}"},
                    {
                        "inline_data": {
                            "mime_type": "image/jpeg",
                            "data": image_b64,
                        }
                    },
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0,
            "responseMimeType": "application/json",
        },
    }
    try:
        url = f"{base_url}/models/{model}:generateContent"
        headers = {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
        }
        response = _post_gemini_generate_content(
            url,
            headers=headers,
            payload=payload,
            model=model,
            image_reference=context.image_reference,
        )
        if response.status_code >= 400:
            logger.warning(
                "Gemini receipt parser HTTP error status=%s model=%s image=%s body=%s",
                response.status_code,
                model,
                context.image_reference,
                response.text[:500],
            )
            raise _gemini_http_exception(response, model)
        response_payload = response.json()
        content = _gemini_content_text(response_payload)
    except HTTPException:
        raise
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=502, detail="Upstream receipt recognition service failed") from exc

    parsed = _json_object_from_text(content)
    parsed.setdefault("recognition", {})
    parsed["recognition"].update(
        {
            "pipeline": pipeline,
            "cloudImageBytes": image_bytes,
        }
    )
    return parsed


def _post_gemini_generate_content(
    url: str,
    *,
    headers: dict[str, str],
    payload: dict[str, Any],
    model: str,
    image_reference: str | None,
) -> httpx.Response:
    transient_statuses = {500, 502, 503, 504}
    max_attempts = 3
    response: httpx.Response | None = None
    for attempt in range(1, max_attempts + 1):
        response = httpx.post(
            url,
            headers=headers,
            json=payload,
            timeout=settings.receipt_cloud_llm_timeout_seconds,
        )
        if response.status_code == 429:
            retry_seconds = _gemini_retry_seconds(response)
            if retry_seconds is None or retry_seconds > 45 or attempt == max_attempts:
                return response
            logger.warning(
                "Gemini receipt parser quota retry status=429 attempt=%s retry_seconds=%.2f model=%s image=%s",
                attempt,
                retry_seconds,
                model,
                image_reference,
            )
            time.sleep(max(retry_seconds, 1.0) + 0.5)
            continue
        if response.status_code not in transient_statuses or attempt == max_attempts:
            return response

        retry_seconds = _gemini_retry_seconds(response)
        delay_seconds = retry_seconds if retry_seconds is not None and retry_seconds <= 10 else 1.5 * attempt
        logger.warning(
            "Gemini receipt parser transient retry status=%s attempt=%s delay_seconds=%.2f model=%s image=%s",
            response.status_code,
            attempt,
            delay_seconds,
            model,
            image_reference,
        )
        time.sleep(delay_seconds)

    return response


def _gemini_retry_seconds(response: httpx.Response) -> float | None:
    retry_after = response.headers.get("retry-after")
    if retry_after:
        try:
            return max(float(retry_after), 0.0)
        except ValueError:
            pass
    try:
        data = response.json()
    except ValueError:
        data = {}
    message = str(((data.get("error") or {}) if isinstance(data, dict) else {}).get("message") or response.text)
    match = re.search(r"retry in\s+([0-9.]+)s", message, re.IGNORECASE)
    if not match:
        return None
    try:
        return max(float(match.group(1)), 0.0)
    except ValueError:
        return None


def _gemini_http_exception(response: httpx.Response, model: str) -> HTTPException:
    if response.status_code == 429:
        retry_seconds = _gemini_retry_seconds(response)
        if retry_seconds is not None:
            return HTTPException(
                status_code=429,
                detail=f"Gemini 무료 인식 한도에 잠시 걸렸습니다. 약 {int(retry_seconds) + 1}초 뒤 다시 시도해 주세요.",
            )
        return HTTPException(
            status_code=429,
            detail="Gemini 무료 인식 한도를 초과했습니다. 잠시 뒤 다시 시도해 주세요.",
        )
    return HTTPException(
        status_code=502,
        detail=f"Gemini 영수증 인식 서버가 응답하지 않습니다. model={model}, status={response.status_code}",
    )


def _cloud_vision_image_base64(context: RecognitionContext) -> tuple[str, int]:
    raw = context.image_path.read_bytes()
    mode = context.vision_preprocess.strip().lower()
    flatten = mode == "flatten" or settings.receipt_cloud_llm_flatten_enabled
    optimized = _optimized_vision_image_bytes(
        raw,
        flatten=flatten,
        max_edge=settings.receipt_cloud_llm_image_max_edge,
        quality=settings.receipt_cloud_llm_image_jpeg_quality,
    )
    return base64.b64encode(optimized).decode("ascii"), len(optimized)


def _gemini_content_text(response_payload: dict[str, Any]) -> str:
    candidates = response_payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        prompt_feedback = response_payload.get("promptFeedback")
        raise HTTPException(status_code=502, detail=f"Gemini returned no candidates: {prompt_feedback}")
    first = candidates[0] if isinstance(candidates[0], dict) else {}
    parts = ((first.get("content") or {}).get("parts") or [])
    text_parts = [
        str(part.get("text") or "")
        for part in parts
        if isinstance(part, dict) and str(part.get("text") or "").strip()
    ]
    if not text_parts:
        raise HTTPException(
            status_code=502,
            detail=f"Gemini returned no text content: {first.get('finishReason')}",
        )
    return "\n".join(text_parts)


def _cloud_receipt_needs_discount_repair(payload: dict[str, Any], currency_code: str) -> bool:
    normalized = _normalize_receipt_payload(dict(payload), currency_code)
    amount, item_sum, delta = _receipt_amount_item_delta(normalized)
    if amount <= 0 or item_sum <= 0:
        return False
    return item_sum > amount and delta > max(1.0, amount * 0.04)


def _cloud_discount_repair_prompt(payload: dict[str, Any], currency_code: str) -> str:
    normalized = _normalize_receipt_payload(dict(payload), currency_code)
    amount, item_sum, delta = _receipt_amount_item_delta(normalized)
    return (
        "Re-read this receipt image and repair the JSON below. Return one valid JSON object only.\n"
        "The previous extraction likely used pre-discount item prices. Many travel receipts show loyalty, "
        "coupon, clubcard, promotion, or savings lines after a subtotal. Examples include CC, CLUBCARD, "
        "coupon, discount, saving, celkova uspora, celková úspora, remise, rabatt, korting, descuento, 할인.\n"
        "Use the final paid total as amount. For items, return the net paid item lineTotal values after "
        "visible discounts. If a discount clearly belongs to a named item, subtract it from that item. "
        "If the receipt only shows a global discount, distribute it proportionally across purchased items. "
        "Do not return negative discount rows because the app cannot settle negative quantities. "
        "The sum of item lineTotal values must reconcile with the final paid total within 0.01 when possible. "
        "Exclude subtotal, tax, payment, card, membership, and footer rows from items.\n"
        f"Fallback currency: {currency_code}.\n"
        f"Previous amount: {amount:g}, previous item sum: {item_sum:g}, delta: {delta:g}.\n"
        f"Previous JSON:\n{json.dumps(normalized, ensure_ascii=False)[:6000]}"
    )


def _parse_image_with_ollama(context: RecognitionContext) -> dict[str, Any]:
    pipeline = settings.receipt_llm_pipeline.strip().lower()
    if pipeline in {"2stage", "two_stage", "transcribe", "transcribe_then_parse"}:
        return _parse_image_with_ollama_two_stage(context)
    parsed = _parse_image_with_ollama_single(context)
    if pipeline in {"fast", "single", "single_pass"}:
        return _with_fast_quality_warning(parsed)
    if pipeline in {"repair", "auto", "balanced"} and settings.receipt_llm_repair_enabled:
        return _repair_receipt_if_needed(parsed, context.currency_code)
    return parsed


def _parse_image_with_ollama_single(context: RecognitionContext) -> dict[str, Any]:
    images_b64 = _vision_llm_images_base64(context)
    content = _ollama_chat_json_content(
        [
            {"role": "system", "content": _vision_llm_system_prompt()},
            {
                "role": "user",
                "content": _vision_llm_user_prompt(context.currency_code),
                "images": images_b64,
            },
        ],
        error_label="Ollama vision parser failed",
    )
    parsed = _json_object_from_text(content)
    parsed.setdefault("recognition", {})
    parsed["recognition"].update({"pipeline": "single_pass"})
    return parsed


def _parse_image_with_ollama_two_stage(context: RecognitionContext) -> dict[str, Any]:
    transcript = _transcribe_image_with_ollama(context)
    parsed = _structure_transcript_with_ollama(transcript, context.currency_code)
    parsed.setdefault("recognition", {})
    parsed["recognition"].update(
        {
            "pipeline": "two_stage",
            "transcriptLineCount": len(transcript.get("rawLines") or []),
            "transcriptWarnings": transcript.get("warnings") or [],
        }
    )
    if settings.receipt_llm_repair_enabled:
        parsed = _repair_receipt_if_needed(parsed, context.currency_code, transcript)
    return parsed


def _transcribe_image_with_ollama(context: RecognitionContext) -> dict[str, Any]:
    images_b64 = _vision_llm_images_base64(context)
    content = _ollama_chat_json_content(
        [
            {"role": "system", "content": _vision_transcript_system_prompt()},
            {
                "role": "user",
                "content": _vision_transcript_user_prompt(context.currency_code),
                "images": images_b64,
            },
        ],
        error_label="Ollama receipt transcription failed",
    )
    transcript = _json_object_from_text(content)
    if not isinstance(transcript.get("rawLines"), list):
        transcript["rawLines"] = []
    return transcript


def _structure_transcript_with_ollama(
    transcript: dict[str, Any],
    currency_code: str,
) -> dict[str, Any]:
    content = _ollama_chat_json_content(
        [
            {"role": "system", "content": _llm_system_prompt()},
            {
                "role": "user",
                "content": _llm_transcript_user_prompt(transcript, currency_code),
            },
        ],
        error_label="Ollama transcript parser failed",
    )
    return _json_object_from_text(content)


def _vision_llm_image_base64(image_path: Path) -> str:
    raw = image_path.read_bytes()
    if _vision_model_prefers_raw_image():
        return base64.b64encode(_qwen_safe_image_bytes(raw)).decode("ascii")
    optimized = _optimized_vision_image_bytes(raw, flatten=settings.receipt_vision_flatten_enabled)
    return base64.b64encode(optimized).decode("ascii")


def _vision_llm_images_base64(context: RecognitionContext) -> list[str]:
    raw = context.image_path.read_bytes()
    mode = context.vision_preprocess.strip().lower()
    if mode == "original":
        return [base64.b64encode(raw).decode("ascii")]
    if mode == "flatten":
        return [base64.b64encode(_optimized_vision_image_bytes(raw, flatten=True)).decode("ascii")]
    if _vision_model_prefers_raw_image():
        return [base64.b64encode(_qwen_safe_image_bytes(raw)).decode("ascii")]

    images: list[bytes] = []
    if settings.receipt_vision_include_original_enabled:
        images.append(_optimized_vision_image_bytes(raw, flatten=False))
    if settings.receipt_vision_flatten_enabled:
        flattened = _optimized_vision_image_bytes(raw, flatten=True)
        if not images or flattened != images[0]:
            images.append(flattened)
    if not images:
        images.append(_optimized_vision_image_bytes(raw, flatten=False))
    return [base64.b64encode(image).decode("ascii") for image in images[:2]]


def _vision_model_prefers_raw_image() -> bool:
    model = settings.receipt_llm_model.strip().lower()
    return model.startswith("qwen2.5vl") or "qwen2.5-vl" in model


def _qwen_safe_image_bytes(raw: bytes) -> bytes:
    if not settings.receipt_qwen_safe_resize_enabled:
        return raw
    edge = int(settings.receipt_qwen_safe_resize_edge or 0)
    if edge <= 0:
        return raw
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        return raw

    source = np.frombuffer(raw, dtype=np.uint8)
    image = cv2.imdecode(source, cv2.IMREAD_COLOR)
    if image is None:
        return raw

    height, width = image.shape[:2]
    longest = max(width, height)
    if longest <= edge:
        return raw

    scale = edge / float(longest)
    # Qwen2.5-VL's Ollama runner is sensitive to image patch geometry; keep
    # dimensions on 28px boundaries and avoid the flattened/enhanced variants.
    resized_width = max(28, int(round(width * scale / 28)) * 28)
    resized_height = max(28, int(round(height * scale / 28)) * 28)
    image = cv2.resize(
        image,
        (resized_width, resized_height),
        interpolation=cv2.INTER_AREA,
    )
    quality = min(95, max(60, int(settings.receipt_llm_image_jpeg_quality or 92)))
    ok, encoded = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    if not ok:
        return raw
    return encoded.tobytes()


def _optimized_vision_image_bytes(
    raw: bytes,
    *,
    flatten: bool,
    max_edge: int | None = None,
    quality: int | None = None,
) -> bytes:
    max_edge = max(640, int(max_edge or settings.receipt_llm_image_max_edge or 1600))
    quality = min(95, max(60, int(quality or settings.receipt_llm_image_jpeg_quality or 86)))
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        return raw

    source = np.frombuffer(raw, dtype=np.uint8)
    image = cv2.imdecode(source, cv2.IMREAD_COLOR)
    if image is None:
        return raw

    if flatten:
        flattened = _flatten_receipt_for_vision(image, cv2, np)
        if flattened is not None:
            image = flattened

    height, width = image.shape[:2]
    longest = max(width, height)
    if longest > max_edge:
        scale = max_edge / float(longest)
        image = cv2.resize(
            image,
            (max(1, int(width * scale)), max(1, int(height * scale))),
            interpolation=cv2.INTER_AREA,
        )

    ok, encoded = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    if not ok:
        return raw
    return encoded.tobytes()


def _flatten_receipt_for_vision(image: Any, cv2: Any, np: Any) -> Any | None:
    normalized = _normalize_image_size(image, cv2)
    warped = _perspective_receipt_crop(normalized, cv2, np)
    if warped is None:
        return _enhance_receipt_for_vision(normalized, cv2)
    return _enhance_receipt_for_vision(warped, cv2)


def _enhance_receipt_for_vision(image: Any, cv2: Any) -> Any:
    try:
        lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
        lightness, channel_a, channel_b = cv2.split(lab)
        clahe = cv2.createCLAHE(clipLimit=1.8, tileGridSize=(8, 8))
        lightness = clahe.apply(lightness)
        enhanced = cv2.merge((lightness, channel_a, channel_b))
        return cv2.cvtColor(enhanced, cv2.COLOR_LAB2BGR)
    except Exception:
        return image


def recognize_receipt_text(
    ocr_text: str,
    currency_code: str = "KRW",
    image_reference: str | None = None,
    recognition_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    cleaned = _clean_ocr_text(ocr_text)
    if not cleaned:
        raise HTTPException(status_code=422, detail="OCR text is empty")

    normalized_currency = _normalize_currency(currency_code)
    cleaned_for_parse = _prepare_ocr_text_for_parsing(cleaned, normalized_currency)
    metadata = recognition_metadata or {}
    llm_parse_text = _ocr_text_with_layout_hints(cleaned_for_parse, metadata, normalized_currency)
    parsed: dict[str, Any] | None = None
    rule_candidate: dict[str, Any] | None = None
    if settings.receipt_rule_first_enabled:
        rule_candidate = _parse_with_rules(cleaned_for_parse, normalized_currency)
        rule_candidate = _apply_layout_total_hints(
            rule_candidate,
            metadata,
            normalized_currency,
        )

    try:
        parsed = _parse_with_llm(llm_parse_text, normalized_currency)
        if parsed is not None:
            parsed.setdefault("recognition", {})
            parsed["recognition"]["textLlmStructured"] = True
    except HTTPException:
        if rule_candidate is None:
            raise
        rule_candidate.setdefault("warnings", [])
        rule_candidate["warnings"].append("LLM 구조화에 실패해 OCR 규칙 파서 결과를 사용했습니다.")
        parsed = rule_candidate
    if parsed is None:
        parsed = rule_candidate or _parse_with_rules(cleaned_for_parse, normalized_currency)
    elif rule_candidate is not None:
        parsed = _best_receipt_candidate(rule_candidate, parsed)

    parsed["imagePath"] = image_reference
    parsed["ocrText"] = cleaned
    parsed.setdefault("warnings", [])
    parsed.setdefault("recognition", {})
    parsed["recognition"].update(
        {
            "ocrProvider": settings.receipt_ocr_provider,
            "llmProvider": settings.receipt_llm_provider,
            "recognizedAt": datetime.now(timezone.utc).isoformat(),
            **metadata,
        }
    )
    return _with_recognition_duration(
        _normalize_receipt_payload(parsed, _normalize_currency(currency_code)),
        started,
    )


def _with_recognition_duration(payload: dict[str, Any], started: float) -> dict[str, Any]:
    elapsed_ms = int(round((time.perf_counter() - started) * 1000))
    payload.setdefault("recognition", {})
    payload["recognition"]["durationMs"] = elapsed_ms
    payload["recognition"]["durationSeconds"] = round(elapsed_ms / 1000, 2)
    recognition = payload.get("recognition") if isinstance(payload.get("recognition"), dict) else {}
    try:
        logger.info(
            "Receipt recognition completed strategy=%s provider=%s model=%s image=%s amount=%s currency=%s items=%s durationMs=%s warnings=%s",
            recognition.get("recognitionStrategy"),
            recognition.get("llmProvider") or recognition.get("ocrProvider"),
            recognition.get("llmModel"),
            payload.get("imagePath"),
            payload.get("amount"),
            payload.get("currencyCode"),
            len(payload.get("items") or []),
            elapsed_ms,
            len(payload.get("warnings") or []),
        )
    except Exception:
        pass
    return payload


def _run_ocr(context: RecognitionContext) -> OcrResult:
    provider = settings.receipt_ocr_provider.strip().lower()
    if provider in {"mock", "disabled"}:
        return OcrResult(
            text=_mock_ocr_text(context.currency_code),
            metadata={"attempts": [{"variant": "mock", "psm": None, "score": 1}]},
        )
    if provider in {"tesseract", "tesseract_cli"}:
        return _run_tesseract(context)
    if provider in {"lightonocr", "lightonocr_service", "ocr_service"}:
        return _run_lightonocr_service(context)
    if provider in {"easyocr", "easyocr_service"}:
        return _run_easyocr_service(context)
    raise HTTPException(
        status_code=503,
        detail=f"Unsupported OCR provider: {settings.receipt_ocr_provider}",
    )


def _run_easyocr_service(context: RecognitionContext) -> OcrResult:
    if context.image_path is None or not context.image_path.exists():
        raise HTTPException(status_code=404, detail="Receipt image not found")

    url = settings.receipt_easyocr_service_url.rstrip("/")
    if not url:
        raise HTTPException(status_code=503, detail="EasyOCR service URL is not configured")

    started = time.perf_counter()
    try:
        with context.image_path.open("rb") as image_file:
            response = httpx.post(
                f"{url}/ocr",
                files={"file": (context.image_path.name, image_file, "application/octet-stream")},
                data={
                    "currencyCode": context.currency_code,
                    "preprocess": context.ocr_preprocess,
                },
                timeout=settings.receipt_recognition_timeout_seconds,
            )
            response.raise_for_status()
            payload = response.json()
    except (httpx.HTTPError, OSError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Upstream receipt recognition service failed") from exc

    text = str(payload.get("text") or "").strip()
    metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
    metadata.update(
        {
            "provider": "easyocr_service",
            "serviceUrl": url,
            "preprocess": context.ocr_preprocess,
            "backendCallDurationMs": int(round((time.perf_counter() - started) * 1000)),
        }
    )
    if not text:
        raise HTTPException(status_code=422, detail="EasyOCR returned empty text")
    return OcrResult(text=text, metadata=metadata)


def _ocr_text_with_layout_hints(
    ocr_text: str,
    metadata: dict[str, Any],
    currency_code: str,
) -> str:
    compact_text = _compact_ocr_text_for_llm(ocr_text, metadata)
    candidates = _layout_total_candidates(metadata, currency_code)
    if not candidates:
        return compact_text
    hint_lines = [
        "OCR layout amount candidates, sorted by likelihood. Use them to reject SKU, barcode, approval, and receipt-number rows:"
    ]
    for candidate in candidates[:12]:
        hint_lines.append(
            "- "
            f"text={candidate['lineText']!r}; amount={candidate['amount']}; "
            f"score={candidate['score']}; reason={','.join(candidate['reasons'])}; "
            f"row={candidate['rowIndex']}"
        )
    return f"{compact_text}\n\n--- OCR_LAYOUT_HINTS ---\n" + "\n".join(hint_lines)


def _compact_ocr_text_for_llm(ocr_text: str, metadata: dict[str, Any]) -> str:
    layout = _layout_lines(metadata)
    if not layout:
        return ocr_text[:6000]

    keep: set[int] = set(range(min(12, len(layout))))
    candidates = _layout_total_candidates(metadata, "KRW")
    for candidate in candidates[:8]:
        row = int(candidate.get("rowIndex") or 0)
        keep.update(range(max(0, row - 2), min(len(layout), row + 3)))

    for index, line in enumerate(layout):
        text = str(line.get("text") or "")
        if (
            _amounts(text)
            or _line_has_total_hint(text)
            or _line_has_currency_hint(text)
            or _looks_like_date(text)
        ):
            keep.add(index)
            if _line_has_total_hint(text):
                keep.update(range(max(0, index - 2), min(len(layout), index + 4)))

    selected = sorted(keep)
    if len(selected) > 95:
        selected = selected[:35] + selected[-60:]

    lines = ["OCR lines with row numbers:"]
    for index in selected:
        text = str(layout[index].get("text") or "").strip()
        if text:
            lines.append(f"{index}: {text}")
    return "\n".join(lines)[:6000]


def _apply_layout_total_hints(
    payload: dict[str, Any],
    metadata: dict[str, Any],
    currency_code: str,
) -> dict[str, Any]:
    candidates = _layout_total_candidates(metadata, currency_code)
    if not candidates:
        return payload

    payload.setdefault("recognition", {})
    payload["recognition"]["layoutTotalCandidates"] = candidates[:8]
    current_amount = _as_float(payload.get("amount"))
    best = candidates[0]
    best_amount = _as_float(best.get("amount"))
    if best_amount <= 0:
        return payload

    recognition = payload.get("recognition") if isinstance(payload.get("recognition"), dict) else {}
    if (
        recognition.get("totalHinted")
        and current_amount > 0
        and current_amount < 10_000
    ):
        return payload

    should_replace = current_amount <= 0 or _amount_looks_like_identifier(current_amount, currency_code)
    if not should_replace and best["score"] >= 4.5:
        delta = abs(current_amount - best_amount)
        should_replace = delta > max(1.0, best_amount * 0.08) and not _amount_looks_like_identifier(best_amount, currency_code)

    if should_replace and not _amount_looks_like_identifier(best_amount, currency_code):
        payload["amount"] = best_amount
        payload["currencyCode"] = _normalize_currency(payload.get("currencyCode") or currency_code)
        payload.setdefault("warnings", [])
        if current_amount > 0 and abs(current_amount - best_amount) > max(1.0, best_amount * 0.08):
            payload["warnings"].append(
                f"OCR 위치 힌트로 총액 후보를 {current_amount:g}에서 {best_amount:g}로 보정했습니다."
            )
        payload["recognition"]["layoutTotalApplied"] = True
    return payload


def _layout_total_candidates(
    metadata: dict[str, Any],
    currency_code: str,
) -> list[dict[str, Any]]:
    lines = _layout_lines(metadata)
    if not lines:
        return []

    width = _as_float(metadata.get("imageWidth"), 0.0)
    currency = _normalize_currency(currency_code)
    candidates: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        text = str(line.get("text") or "")
        if not text.strip():
            continue
        previous = str(lines[index - 1].get("text") or "") if index > 0 else ""
        next_text = str(lines[index + 1].get("text") or "") if index + 1 < len(lines) else ""
        amounts = _amounts(text)
        if not amounts and (_line_has_total_hint(text) or _line_has_total_hint(previous)):
            amounts = _amounts(next_text)
            text = f"{text} {next_text}".strip()
        for amount in amounts:
            if not _is_plausible_receipt_amount(amount, text, previous):
                continue
            score, reasons = _layout_amount_score(
                amount=amount,
                line=line,
                line_text=text,
                previous_text=previous,
                next_text=next_text,
                image_width=width,
                currency_code=currency,
            )
            if score <= 0:
                continue
            candidates.append(
                {
                    "amount": amount,
                    "lineText": text[:180],
                    "rowIndex": index,
                    "score": round(score, 3),
                    "reasons": reasons,
                    "xCenter": line.get("xCenter"),
                    "yCenter": line.get("yCenter"),
                    "confidence": line.get("confidence"),
                }
            )
    candidates.sort(key=lambda item: (item["score"], item["amount"]), reverse=True)
    return candidates


def _layout_lines(metadata: dict[str, Any]) -> list[dict[str, Any]]:
    raw = metadata.get("layoutLines")
    if not isinstance(raw, list):
        return []
    lines = [line for line in raw if isinstance(line, dict) and str(line.get("text") or "").strip()]
    return sorted(
        lines,
        key=lambda line: (
            _as_float(line.get("yCenter")),
            _as_float(line.get("xCenter")),
        ),
    )


def _layout_amount_score(
    *,
    amount: float,
    line: dict[str, Any],
    line_text: str,
    previous_text: str,
    next_text: str,
    image_width: float,
    currency_code: str,
) -> tuple[float, list[str]]:
    lower = line_text.lower()
    previous_lower = previous_text.lower()
    next_lower = next_text.lower()
    reasons: list[str] = []
    score = 0.0

    if _line_has_total_hint(lower):
        score += 4.0
        reasons.append("total-line")
    if _line_has_total_hint(previous_lower):
        score += 3.0
        reasons.append("after-total-label")
    if _line_has_total_hint(next_lower):
        score += 1.0
        reasons.append("before-total-label")
    if _line_has_currency_hint(line_text):
        score += 1.25
        reasons.append("currency")

    x_center = _as_float(line.get("xCenter"))
    if image_width > 0 and x_center > image_width * 0.58:
        score += 0.75
        reasons.append("right-column")

    if re.search(r"\d+[.,]\d{1,2}", line_text):
        score += 0.8
        reasons.append("decimal")
    if _amount_looks_like_identifier(amount, currency_code):
        score -= 4.0
        reasons.append("identifier-like")
    if _is_metadata_line(line_text) or _is_metadata_line(previous_text):
        score -= 2.5
        reasons.append("metadata-nearby")
    if re.search(r"\b(?:sku|item\s*no|barcode|ean|plu|code)\b", lower, re.IGNORECASE):
        score -= 2.5
        reasons.append("code-row")
    if re.search(r"\b\d{5,}\b", line_text) and not (_line_has_total_hint(lower) or _line_has_currency_hint(line_text)):
        score -= 1.5
        reasons.append("long-integer")
    if _line_has_non_payable_total_context(lower) or _line_has_non_payable_total_context(previous_lower) or _line_has_non_payable_total_context(next_lower):
        score -= 4.0
        reasons.append("discount-or-nonpayable")

    if amount > 0 and amount < 1_000_000:
        score += 0.2
    return score, reasons


def _amount_looks_like_identifier(amount: float, currency_code: str) -> bool:
    currency = _normalize_currency(currency_code)
    if currency in {"JPY", "KRW", "VND", "HUF", "ISK"}:
        return amount >= 10_000_000
    if amount >= 10_000:
        return True
    text = f"{amount:g}"
    return "." not in text and amount >= 1000


def _line_has_non_payable_total_context(line: str) -> bool:
    lower = line.lower()
    return any(
        token in lower
        for token in (
            "discount",
            "descuento",
            "coupon",
            "voucher",
            "change",
            "cashback",
            "refund",
            "saving",
            "tax",
            "vat",
            "iva",
            "할인",
            "쿠폰",
            "거스름",
            "부가세",
            "세금",
        )
    )


def _run_lightonocr_service(context: RecognitionContext) -> OcrResult:
    if context.image_path is None or not context.image_path.exists():
        raise HTTPException(status_code=404, detail="Receipt image not found")

    url = settings.receipt_ocr_service_url.rstrip("/")
    if not url:
        raise HTTPException(status_code=503, detail="LightOnOCR service URL is not configured")

    started = time.perf_counter()
    try:
        with context.image_path.open("rb") as image_file:
            response = httpx.post(
                f"{url}/ocr",
                files={"file": (context.image_path.name, image_file, "application/octet-stream")},
                data={
                    "prompt": (
                        "Extract only visible receipt text lines in natural reading order. "
                        "Preserve item rows, dates, totals, currencies, and prices. "
                        "Do not invent hidden card numbers or repeated filler digits."
                    )
                },
                timeout=settings.receipt_recognition_timeout_seconds,
            )
            response.raise_for_status()
            payload = response.json()
    except (httpx.HTTPError, OSError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Upstream receipt recognition service failed") from exc

    text = str(payload.get("text") or "").strip()
    metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
    service_duration_ms = metadata.pop("durationMs", None)
    service_duration_seconds = metadata.pop("durationSeconds", None)
    metadata.update(
        {
            "provider": "lightonocr_service",
            "serviceUrl": url,
            "ocrDurationMs": service_duration_ms,
            "ocrDurationSeconds": service_duration_seconds,
            "backendCallDurationMs": int(round((time.perf_counter() - started) * 1000)),
        }
    )
    if not text:
        raise HTTPException(status_code=422, detail="LightOnOCR returned empty text")
    return OcrResult(text=text, metadata=metadata)


def _run_tesseract(context: RecognitionContext) -> OcrResult:
    if context.image_path is None or not context.image_path.exists():
        raise HTTPException(status_code=404, detail="Receipt image not found")

    best: tuple[float, str, dict[str, Any]] | None = None
    attempts: list[dict[str, Any]] = []
    errors: list[str] = []

    with tempfile.TemporaryDirectory(prefix="tripscript_ocr_") as tmp:
        variants = _ocr_image_variants(context.image_path, Path(tmp))
        for variant_name, candidate_path in variants:
            for psm in _ocr_psm_modes():
                try:
                    text = _run_tesseract_once(candidate_path, psm)
                except HTTPException as exc:
                    errors.append(str(exc.detail))
                    attempts.append(
                        {
                            "variant": variant_name,
                            "psm": psm,
                            "score": 0,
                            "error": str(exc.detail),
                        }
                    )
                    continue

                score = _score_ocr_text(text)
                attempts.append(
                    {
                        "variant": variant_name,
                        "psm": psm,
                        "score": round(score, 3),
                        "textLength": len(_clean_ocr_text(text)),
                    }
                )
                if best is None or score > best[0]:
                    best = (
                        score,
                        text,
                        {
                            "selectedVariant": variant_name,
                            "selectedPsm": psm,
                            "ocrScore": round(score, 3),
                            "preprocessEnabled": settings.receipt_image_preprocess_enabled,
                            "variantCount": len(variants),
                            "attempts": attempts,
                        },
                    )

    if best is None:
        detail = errors[-1] if errors else "Tesseract OCR failed"
        raise HTTPException(status_code=502, detail=detail)
    return OcrResult(text=best[1], metadata=best[2])


def _run_tesseract_once(image_path: Path, psm: int) -> str:
    command = [
        "tesseract",
        str(image_path),
        "stdout",
        "-l",
        settings.receipt_ocr_langs,
        "--oem",
        "1",
        "--psm",
        str(psm),
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=settings.receipt_recognition_timeout_seconds,
        )
    except FileNotFoundError as exc:
        raise HTTPException(
            status_code=503,
            detail="Tesseract OCR is not installed in the backend image",
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=504, detail="OCR timed out") from exc

    if result.returncode != 0:
        raise HTTPException(
            status_code=502,
            detail=f"Tesseract OCR failed: {result.stderr.strip() or result.stdout.strip()}",
        )
    return result.stdout


def _ocr_psm_modes() -> list[int]:
    raw = str(settings.receipt_ocr_psm_modes or "").strip()
    modes: list[int] = []
    for part in re.split(r"[, ]+", raw):
        if not part:
            continue
        try:
            value = int(part)
        except ValueError:
            continue
        if value not in modes:
            modes.append(value)
    if not modes:
        modes = [int(settings.receipt_ocr_psm)]
    return modes


def _ocr_image_variants(image_path: Path, tmp_dir: Path) -> list[tuple[str, Path]]:
    variants: list[tuple[str, Path]] = [("original", image_path)]
    if not settings.receipt_image_preprocess_enabled:
        return variants

    try:
        import cv2
        import numpy as np
    except ImportError:
        return variants

    image = cv2.imread(str(image_path))
    if image is None:
        return variants

    sources: list[tuple[str, Any]] = [("normalized", _normalize_image_size(image, cv2))]
    warped = _perspective_receipt_crop(sources[0][1], cv2, np)
    if warped is not None:
        sources.append(("deskewed", warped))

    saved_names: set[str] = set()
    for source_name, source in sources:
        for variant_name, variant in _preprocess_source_image(source, cv2):
            name = f"{source_name}_{variant_name}"
            if name in saved_names:
                continue
            saved_names.add(name)
            target = tmp_dir / f"{uuid4().hex}_{name}.png"
            if cv2.imwrite(str(target), variant):
                variants.append((name, target))
    return variants


def _normalize_image_size(image: Any, cv2: Any) -> Any:
    height, width = image.shape[:2]
    longest = max(width, height)
    shortest = min(width, height)
    scale = 1.0
    if longest > 3200:
        scale = 3200 / longest
    elif shortest < 1400:
        scale = 1400 / shortest
    if abs(scale - 1.0) < 0.01:
        return image
    interpolation = cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=interpolation)


def _perspective_receipt_crop(image: Any, cv2: Any, np: Any) -> Any | None:
    height, width = image.shape[:2]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 160)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    edges = cv2.dilate(edges, kernel, iterations=1)
    contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None

    image_area = float(width * height)
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:8]:
        area = cv2.contourArea(contour)
        if area < image_area * 0.12:
            continue
        perimeter = cv2.arcLength(contour, True)
        approx = cv2.approxPolyDP(contour, 0.02 * perimeter, True)
        if len(approx) != 4:
            rect = cv2.minAreaRect(contour)
            approx = cv2.boxPoints(rect).astype("float32").reshape(4, 1, 2)
        points = approx.reshape(4, 2).astype("float32")
        ordered = _order_points(points, np)
        warped = _four_point_transform(image, ordered, cv2, np)
        if warped is not None:
            return warped
    return None


def _order_points(points: Any, np: Any) -> Any:
    rect = np.zeros((4, 2), dtype="float32")
    sums = points.sum(axis=1)
    diffs = np.diff(points, axis=1)
    rect[0] = points[np.argmin(sums)]
    rect[2] = points[np.argmax(sums)]
    rect[1] = points[np.argmin(diffs)]
    rect[3] = points[np.argmax(diffs)]
    return rect


def _four_point_transform(image: Any, points: Any, cv2: Any, np: Any) -> Any | None:
    top_left, top_right, bottom_right, bottom_left = points
    width_a = np.linalg.norm(bottom_right - bottom_left)
    width_b = np.linalg.norm(top_right - top_left)
    height_a = np.linalg.norm(top_right - bottom_right)
    height_b = np.linalg.norm(top_left - bottom_left)
    max_width = int(max(width_a, width_b))
    max_height = int(max(height_a, height_b))
    if max_width < 300 or max_height < 300:
        return None
    destination = np.array(
        [[0, 0], [max_width - 1, 0], [max_width - 1, max_height - 1], [0, max_height - 1]],
        dtype="float32",
    )
    matrix = cv2.getPerspectiveTransform(points, destination)
    return cv2.warpPerspective(image, matrix, (max_width, max_height))


def _preprocess_source_image(image: Any, cv2: Any) -> list[tuple[str, Any]]:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    enhanced = clahe.apply(gray)
    denoised = cv2.fastNlMeansDenoising(enhanced, None, 10, 7, 21)
    threshold = cv2.adaptiveThreshold(
        denoised,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY,
        31,
        11,
    )
    upscaled = cv2.resize(threshold, None, fx=1.6, fy=1.6, interpolation=cv2.INTER_CUBIC)
    return [
        ("gray", gray),
        ("enhanced", enhanced),
        ("threshold", threshold),
        ("upscaled_threshold", upscaled),
    ]


def _score_ocr_text(text: str) -> float:
    cleaned = _clean_ocr_text(text)
    if not cleaned:
        return 0.0
    lines = [line for line in cleaned.splitlines() if line.strip()]
    amount_count = sum(len(_amounts(line)) for line in lines)
    total_hints = sum(
        1
        for line in lines
        if any(token in line.lower() for token in ("total", "amount", "합계", "총액", "결제금액"))
    )
    date_found = 1 if any(_looks_like_date(line) for line in lines) else 0
    alpha_numeric = sum(1 for char in cleaned if char.isalnum())
    replacement_penalty = cleaned.count("?") + cleaned.count("�")
    return (
        alpha_numeric * 0.03
        + len(lines) * 1.5
        + amount_count * 7.0
        + total_hints * 15.0
        + date_found * 12.0
        - replacement_penalty * 3.0
    )


def _looks_like_date(line: str) -> bool:
    return bool(
        re.search(r"20\d{2}[-./년 ]+\d{1,2}[-./월 ]+\d{1,2}", line)
        or re.search(r"\d{1,2}[-./]\d{1,2}[-./]20\d{2}", line)
    )


def _parse_with_llm(ocr_text: str, currency_code: str) -> dict[str, Any] | None:
    provider = settings.receipt_llm_provider.strip().lower()
    if provider in {"", "none", "rule", "rules", "disabled"}:
        return None
    if provider in {"ollama", "ollama_vision", "ollama_image", "ollama_multimodal"}:
        return _parse_with_ollama(ocr_text, currency_code)
    if provider in {"openai_compatible", "chat_completions"}:
        return _parse_with_openai_compatible(ocr_text, currency_code)
    raise HTTPException(
        status_code=503,
        detail=f"Unsupported LLM provider: {settings.receipt_llm_provider}",
    )


def _parse_with_ollama(ocr_text: str, currency_code: str) -> dict[str, Any]:
    content = _ollama_chat_json_content(
        [
            {"role": "system", "content": _llm_system_prompt()},
            {"role": "user", "content": _llm_user_prompt(ocr_text, currency_code)},
        ],
        error_label="Ollama receipt parser failed",
        model=settings.receipt_text_llm_model,
        num_ctx=settings.receipt_text_llm_num_ctx,
        num_predict=settings.receipt_text_llm_num_predict,
        timeout_seconds=settings.receipt_text_llm_timeout_seconds,
    )
    return _json_object_from_text(content)


def _ollama_chat_json_content(
    messages: list[dict[str, Any]],
    *,
    error_label: str,
    model: str | None = None,
    num_ctx: int | None = None,
    num_predict: int | None = None,
    timeout_seconds: int | None = None,
) -> str:
    url = settings.receipt_llm_base_url.rstrip("/") or "http://ollama:11434"
    selected_model = (model or settings.receipt_llm_model).strip()
    payload: dict[str, Any] = {
        "model": selected_model,
        "stream": False,
        "format": "json",
        "messages": messages,
        "options": {
            "temperature": 0,
            "num_ctx": _ollama_num_ctx(selected_model, num_ctx),
            "num_predict": int(num_predict or settings.receipt_llm_num_predict),
        },
    }
    if settings.receipt_llm_keep_alive.strip():
        payload["keep_alive"] = settings.receipt_llm_keep_alive.strip()
    try:
        response = httpx.post(
            f"{url}/api/chat",
            json=payload,
            timeout=timeout_seconds or settings.receipt_recognition_timeout_seconds,
        )
        response.raise_for_status()
        content = response.json()["message"]["content"]
    except (httpx.HTTPError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=502, detail="Upstream receipt recognition service failed") from exc
    return str(content or "")


def _ollama_num_ctx(model: str | None = None, requested_num_ctx: int | None = None) -> int:
    num_ctx = int(requested_num_ctx or settings.receipt_llm_num_ctx or 8192)
    model_name = (model or settings.receipt_llm_model).strip().lower()
    if model_name.startswith("qwen2.5vl") or "qwen2.5-vl" in model_name:
        return max(num_ctx, 8192)
    return num_ctx


def _fast_ocr_needs_vision_fallback(
    payload: dict[str, Any],
    ocr_text: str,
    currency_code: str,
) -> bool:
    normalized = _normalize_receipt_payload(payload, currency_code)
    amount, item_sum, delta = _receipt_amount_item_delta(normalized)
    warnings = normalized.setdefault("warnings", [])
    currency = _normalize_currency(normalized.get("currencyCode") or currency_code)
    fallback_currency = _normalize_currency(currency_code)

    if amount <= 0:
        warnings.append("OCR/텍스트 구조화 경로에서 총액을 확정하지 못했습니다.")
        return True
    if currency != fallback_currency:
        warnings.append("OCR/텍스트 구조화 경로에서 요청 통화와 다른 통화가 감지되었습니다.")
        return True
    if _as_float(normalized.get("confidence"), 0.5) < 0.45:
        warnings.append("OCR/텍스트 구조화 경로의 신뢰도가 낮습니다.")
        return True
    if item_sum > 0 and delta > max(1.0, amount * 0.08):
        warnings.append("OCR/텍스트 구조화 경로의 품목 합계와 총액 차이가 큽니다.")

    rule_text = _prepare_ocr_text_for_parsing(_clean_ocr_text(ocr_text), fallback_currency)
    rule_candidate = _parse_with_rules(rule_text, fallback_currency)
    rule_amount = _as_float(rule_candidate.get("amount"))
    if rule_amount > 0 and abs(rule_amount - amount) > max(1.0, amount * 0.08):
        warnings.append("OCR/텍스트 구조화 경로와 규칙 파서의 총액 후보가 다릅니다.")
        return True

    monetary_candidates = _ocr_monetary_candidates_for_validation(ocr_text)
    if monetary_candidates:
        max_candidate = max(monetary_candidates)
        zero_decimal_currency = currency in {"JPY", "KRW", "VND"}
        if zero_decimal_currency and max_candidate >= 1000 and amount < max_candidate * 0.5:
            warnings.append("OCR/텍스트 구조화 경로에서 0이 누락된 총액 후보가 감지되었습니다.")
            return True
        if max_candidate > max(amount * 8, amount + 1000) and amount < max_candidate:
            warnings.append("OCR/텍스트 구조화 경로에서 총액보다 훨씬 큰 금액 후보가 감지되었습니다.")
            return True

    normalized.setdefault("recognition", {})
    normalized["recognition"]["fastValidation"] = {
        "amount": amount,
        "itemSum": item_sum,
        "ruleAmount": rule_amount,
        "maxOcrAmountCandidate": max(monetary_candidates) if monetary_candidates else None,
    }
    payload.update(normalized)
    return False


def _ocr_monetary_candidates_for_validation(ocr_text: str) -> list[float]:
    candidates: list[float] = []
    for line in _clean_ocr_text(ocr_text).splitlines():
        if _is_metadata_line(line):
            continue
        lower = line.lower()
        has_total_hint = any(
            hint in lower
            for hint in ("total", "amount", "합계", "총액", "결제금액", "合計", "금액")
        )
        has_currency_hint = bool(
            re.search(r"[₩€£$¥]|\b(?:krw|usd|eur|gbp|jpy|chf|cny|thb|vnd)\b", line, re.IGNORECASE)
            # EasyOCR often reads pound/euro symbols as a leading f/e/o.
            or re.search(r"\b[fFeEoO]\s*\d+[.,]\d{1,2}\b", line)
        )
        has_decimal_amount = bool(re.search(r"\d+[.,]\d{1,2}\b", line))
        if not (has_total_hint or has_currency_hint or has_decimal_amount):
            continue
        for value in _amounts(line):
            if value > 0:
                candidates.append(value)
    return candidates


def _should_reprocess_receipt(payload: dict[str, Any]) -> bool:
    amount, item_sum, delta = _receipt_amount_item_delta(payload)
    confidence = _as_float(payload.get("confidence"), 0.5)
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    currency = _normalize_currency(payload.get("currencyCode") or payload.get("currency") or "KRW")
    if amount <= 0 or confidence < 0.55 or not items:
        return True
    if _amount_looks_like_identifier(amount, currency):
        return True
    if len(items) == 1 and str(items[0].get("name") or "").strip() == "영수증 총액":
        return True
    if item_sum > 0 and delta > max(1.0, amount * 0.04):
        return len(items) < 3
    return False


def _with_fast_quality_warning(payload: dict[str, Any]) -> dict[str, Any]:
    if not _should_reprocess_receipt(payload):
        return payload
    payload.setdefault("warnings", [])
    payload["warnings"].append("자동 인식 결과가 불안정할 수 있어 저장 전에 총액과 품목을 확인하세요.")
    payload.setdefault("recognition", {})
    payload["recognition"]["needsReview"] = True
    return payload


def _repair_receipt_if_needed(
    payload: dict[str, Any],
    currency_code: str,
    transcript: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not _should_reprocess_receipt(payload):
        return payload
    try:
        content = _ollama_chat_json_content(
            [
                {"role": "system", "content": _llm_system_prompt()},
                {
                    "role": "user",
                    "content": _llm_repair_user_prompt(payload, currency_code, transcript),
                },
            ],
            error_label="Ollama receipt repair failed",
        )
        repaired = _json_object_from_text(content)
        repaired.setdefault("recognition", {})
        repaired["recognition"].update(payload.get("recognition") or {})
        repaired["recognition"]["repairApplied"] = True
        return _best_receipt_candidate(payload, repaired)
    except HTTPException:
        payload.setdefault("warnings", [])
        payload["warnings"].append("LLM 보정에 실패했습니다. 저장 전에 내용을 확인하세요.")
        return payload


def _best_receipt_candidate(
    first: dict[str, Any],
    second: dict[str, Any],
) -> dict[str, Any]:
    first_amount = _as_float(first.get("amount"))
    second_amount = _as_float(second.get("amount"))
    first_recognition = first.get("recognition") if isinstance(first.get("recognition"), dict) else {}
    second_recognition = second.get("recognition") if isinstance(second.get("recognition"), dict) else {}
    if (
        first_amount > 0
        and second_amount > 0
        and abs(first_amount - second_amount) > max(1.0, first_amount * 0.02)
        and first_recognition.get("totalHinted")
        and first_amount < 10_000
        and not second_recognition.get("totalHinted")
    ):
        first.setdefault("warnings", [])
        first["warnings"].append("LLM 구조화 결과가 명확한 총액 라벨과 달라 OCR 총액을 유지했습니다.")
        return first
    return second if _receipt_quality_score(second) >= _receipt_quality_score(first) else first


def _receipt_quality_score(payload: dict[str, Any]) -> float:
    amount, item_sum, delta = _receipt_amount_item_delta(payload)
    confidence = _as_float(payload.get("confidence"), 0.5)
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    score = confidence + min(len(items), 20) * 0.02
    if not str(payload.get("storeName") or payload.get("store_name") or "").strip():
        score -= 0.08
    if amount <= 0:
        score -= 0.5
    if amount > 0 and item_sum > 0:
        score -= min(delta / max(amount, 1.0), 1.0) * 0.6
    if not items:
        score -= 0.25
    return score


def _receipt_amount_item_delta(payload: dict[str, Any]) -> tuple[float, float, float]:
    amount = _as_float(payload.get("amount") or payload.get("localTotalAmount") or payload.get("total"))
    items = payload.get("items") if isinstance(payload.get("items"), list) else []
    item_sum = sum(_as_float(item.get("lineTotal") or item.get("line_total")) for item in items if isinstance(item, dict))
    return amount, item_sum, abs(amount - item_sum)


def _parse_with_openai_compatible(ocr_text: str, currency_code: str) -> dict[str, Any]:
    if not settings.receipt_llm_api_key:
        raise HTTPException(status_code=503, detail="RECEIPT_LLM_API_KEY is not configured")
    base_url = settings.receipt_llm_base_url.rstrip("/")
    if not base_url:
        raise HTTPException(status_code=503, detail="RECEIPT_LLM_BASE_URL is not configured")

    try:
        response = httpx.post(
            f"{base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.receipt_llm_api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": settings.receipt_llm_model,
                "temperature": 0,
                "messages": [
                    {"role": "system", "content": _llm_system_prompt()},
                    {"role": "user", "content": _llm_user_prompt(ocr_text, currency_code)},
                ],
            },
            timeout=settings.receipt_recognition_timeout_seconds,
        )
        response.raise_for_status()
        content = response.json()["choices"][0]["message"]["content"]
    except (httpx.HTTPError, KeyError, TypeError) as exc:
        raise HTTPException(
            status_code=502,
            detail="Upstream receipt recognition service failed",
        ) from exc
    return _json_object_from_text(content)


def _parse_with_rules(ocr_text: str, currency_code: str) -> dict[str, Any]:
    lines = [line.strip() for line in ocr_text.splitlines() if line.strip()]
    amounts_by_line = [(line, _amounts(line)) for line in lines]
    amount_candidates = [
        amount
        for index, (line, amounts) in enumerate(amounts_by_line)
        if _is_amount_candidate_line(line, lines[index - 1] if index > 0 else "")
        for amount in amounts
        if _is_plausible_receipt_amount(amount, line, lines[index - 1] if index > 0 else "")
    ]
    hinted_totals = _hinted_total_amounts(lines, amounts_by_line)
    total = _guess_total(lines, amounts_by_line, amount_candidates)
    items = _guess_items(lines, total, currency_code)
    if not items and total > 0:
        items = [
            {
                "name": "영수증 총액",
                "quantity": 1,
                "unitPrice": total,
                "lineTotal": total,
                "category": "기타",
                "confidence": 0.35,
                "quantityByPerson": {},
            }
        ]

    item_sum = sum(float(item.get("lineTotal") or 0) for item in items)
    warnings: list[str] = []
    if total <= 0 and item_sum > 0:
        total = item_sum
        warnings.append("총액을 찾지 못해 품목 합계를 사용했습니다.")
    if total > 0 and item_sum > 0 and abs(total - item_sum) > max(1.0, total * 0.05):
        warnings.append("OCR 품목 합계와 영수증 총액이 다릅니다. 저장 전에 확인하세요.")

    return {
        "storeName": _guess_store_name(lines),
        "amount": total,
        "date": _guess_date(lines),
        "category": _guess_category(lines, items),
        "currencyCode": _guess_currency(lines, currency_code),
        "items": items,
        "confidence": 0.55 if items else 0.35,
        "warnings": warnings,
        "recognition": {
            "parser": "rule",
            "totalHinted": any(abs(total - amount) <= max(0.01, total * 0.001) for amount in hinted_totals),
        },
    }


def _normalize_receipt_payload(payload: dict[str, Any], fallback_currency: str) -> dict[str, Any]:
    raw_amount = payload.get("amount") or payload.get("localTotalAmount") or payload.get("total")
    amount = _as_float(raw_amount)
    currency = _normalize_currency(
        payload.get("currencyCode")
        or payload.get("currency")
        or (raw_amount.get("currencyCode") if isinstance(raw_amount, dict) else None)
        or (raw_amount.get("currency") if isinstance(raw_amount, dict) else None)
        or fallback_currency
    )
    items = [
        _normalize_item(item)
        for item in payload.get("items", [])
        if isinstance(item, dict)
    ]
    items = [item for item in items if item["name"] and item["lineTotal"] >= 0]
    if amount > 0:
        sane_items = [
            item
            for item in items
            if item["lineTotal"] <= max(amount * 1.2, amount + 3)
        ]
        if len(sane_items) != len(items):
            items = sane_items
            payload.setdefault("warnings", [])
            payload["warnings"].append("총액보다 과도하게 큰 품목 금액을 제외했습니다.")
    items = _reconcile_small_item_delta(items, amount, currency)

    date_value = payload.get("date") or payload.get("paymentDate") or payload.get("paymentDatetime")
    date = _normalize_date(date_value)
    category = _normalize_category(payload.get("category") or _guess_category([], items) or "기타")
    store_name = str(payload.get("storeName") or payload.get("store_name") or "").strip()
    confidence = _as_float(payload.get("confidence"), 0.5)
    warnings = [_normalize_warning(w) for w in payload.get("warnings", []) if str(w).strip()]
    item_sum = sum(float(item.get("lineTotal") or 0) for item in items)
    if amount <= 0 and item_sum > 0:
        amount = round(item_sum, 2)
        warnings.append("총액을 찾지 못해 품목 합계를 사용했습니다.")
    if amount > 0 and item_sum > 0:
        delta = abs(amount - item_sum)
        if delta > max(1.0, amount * 0.04):
            warnings.append(
                f"영수증 총액({amount:g})과 품목 합계({item_sum:g})가 다릅니다. 저장 전에 확인하세요."
            )
            confidence = min(confidence, 0.55)

    return {
        "storeName": store_name,
        "amount": amount,
        "date": date,
        "category": category,
        "currencyCode": currency,
        "items": items,
        "confidence": confidence,
        "warnings": list(dict.fromkeys(warnings)),
        "ocrText": str(payload.get("ocrText") or ""),
        "imagePath": payload.get("imagePath"),
        "recognition": payload.get("recognition", {}),
    }


def _reconcile_small_item_delta(
    items: list[dict[str, Any]],
    amount: float,
    currency: str,
) -> list[dict[str, Any]]:
    if amount <= 0 or not items:
        return items
    item_sum = sum(float(item.get("lineTotal") or 0) for item in items)
    delta = amount - item_sum
    minor_unit = _currency_minor_unit(currency)
    tolerance = 1.0 if minor_unit == 0 else 0.5
    if abs(delta) <= 0 or abs(delta) > tolerance:
        return items
    target_index = next(
        (
            index
            for index in range(len(items) - 1, -1, -1)
            if (items[index].get("lineTotal") or 0) + delta >= 0
        ),
        None,
    )
    if target_index is None:
        return items
    adjusted = [dict(item) for item in items]
    target = adjusted[target_index]
    new_total = round(float(target.get("lineTotal") or 0) + delta, minor_unit)
    target["lineTotal"] = new_total
    quantity = _as_float(target.get("quantity"), 1.0) or 1.0
    target["unitPrice"] = round(new_total / quantity, minor_unit)
    return adjusted


def _currency_minor_unit(currency: str) -> int:
    return 0 if _normalize_currency(currency) in {"JPY", "KRW", "VND"} else 2


def _normalize_item(item: dict[str, Any]) -> dict[str, Any]:
    quantity = _as_float(item.get("quantity"), 1.0)
    line_total = _as_float(
        item.get("lineTotal")
        or item.get("line_total")
        or item.get("totalPrice")
        or item.get("total_price")
        or item.get("amount")
        or item.get("price")
    )
    unit_price = _as_float(
        item.get("unitPrice")
        or item.get("unit_price")
        or item.get("price"),
        line_total / quantity if quantity else line_total,
    )
    name = str(item.get("name") or item.get("itemName") or item.get("description") or "").strip()[:160]
    translated_name = str(
        item.get("translatedName")
        or item.get("translated_name")
        or item.get("koreanName")
        or item.get("korean_name")
        or ""
    ).strip()[:160]
    return {
        "name": name,
        "translatedName": translated_name or name,
        "quantity": quantity if quantity > 0 else 1.0,
        "unitPrice": unit_price,
        "lineTotal": line_total,
        "category": _normalize_category(item.get("category") or "기타"),
        "quantityByPerson": {},
        "confidence": _as_float(item.get("confidence"), 0.6),
    }


def _normalize_category(value: Any) -> str:
    raw = str(value or "기타").strip()
    categories = ("식비", "카페", "교통", "숙박", "관광", "쇼핑", "마트", "문화", "의료", "통신", "기타")
    for category in categories:
        if category in raw:
            return category
    return "기타"


def _normalize_warning(value: Any) -> str:
    if isinstance(value, dict):
        try:
            return json.dumps(value, ensure_ascii=False)
        except TypeError:
            return str(value)
    return str(value)


def _llm_system_prompt() -> str:
    return (
        "You parse OCR text from travel receipts. Return JSON only. "
        "Do not wrap the JSON in Markdown. Use the exact app schema."
    )


def _vision_llm_system_prompt() -> str:
    return (
        "You are a precise receipt recognition engine for a travel settlement app. "
        "Read the receipt image directly and return JSON only. Do not use Markdown. "
        "Do not invent values that are not visible. Prefer the final paid total over subtotal/tax. "
        "For item rows, exclude metadata, addresses, approval numbers, card numbers, tax-only rows, "
        "subtotals, and footer text. Preserve purchased item names in the original visible language "
        "as item.name, and put a short Korean meaning in item.translatedName."
    )


def _vision_transcript_system_prompt() -> str:
    return (
        "You are a receipt image transcription engine. Return JSON only. "
        "Read visible text top-to-bottom and preserve line order, currency symbols, quantities, "
        "decimal separators, and totals. Do not translate, summarize, or infer hidden values."
    )


def _vision_llm_user_prompt(currency_code: str) -> str:
    return (
        "Extract this receipt image into this exact JSON schema:\n"
        "{"
        '"storeName": string, '
        '"amount": number, '
        '"date": "YYYY-MM-DD", '
        '"category": "식비|카페|교통|숙박|관광|쇼핑|마트|문화|의료|통신|기타", '
        '"currencyCode": string, '
        '"confidence": number, '
        '"warnings": string[], '
        '"items": ['
        '{"name": string, "translatedName": string, "quantity": number, "unitPrice": number, '
        '"lineTotal": number, "category": string, "confidence": number}'
        "]"
        "}\n"
        f"Fallback currencyCode is {currency_code}. "
        "If the receipt shows a currency symbol or ISO code, use that instead. "
        "For every purchased item, item.name must be the original visible receipt text. "
        "Do not translate item.name. Add item.translatedName in Korean as a short practical meaning, "
        "for example 물, 커피, 빵, 도시락, 지하철, 입장권, 생필품, 과자. "
        "If the original text is already Korean, translatedName may equal name. "
        "Map local currency markers to ISO codes: Kč/KC/Kc=Kč/Czech koruna=CZK, "
        "€=EUR, £=GBP, ¥/円=JPY, ₩=KRW, CHF/Fr=SFr=CHF, zł/PLN=PLN, "
        "Ft/HUF=HUF, kr with Denmark/Norway/Sweden context=DKK/NOK/SEK, lei/RON=RON. "
        "Do not keep the fallback currency when a local marker is clearly printed near prices or totals. "
        "If the date is missing, use today's date. If quantity is missing, use 1. "
        "If unit price is missing, use lineTotal divided by quantity. "
        "If the receipt shows coupon, loyalty, clubcard, promotion, or savings discounts, "
        "return net paid item lineTotal values after discounts, not pre-discount subtotal values. "
        "Apply item-specific discounts to their items; distribute global discounts proportionally. "
        "Do not include negative discount rows. "
        "The sum of item lineTotal values should match the final paid total when visible. "
        "If the image is unclear, still return the best JSON and add Korean warnings."
    )


def _cloud_vision_user_prompt(currency_code: str) -> str:
    return (
        f"{_vision_llm_user_prompt(currency_code)}\n"
        "This is a cloud comparison path. Return one valid JSON object only. "
        "Keep numeric values as numbers, not strings. "
        "Do not include code fences, explanations, or extra top-level keys. "
        "When there are multiple totals, choose the final paid/card/cash total. "
        "For receipts outside Korea, preserve the local currency shown on the receipt."
    )


def _vision_transcript_user_prompt(currency_code: str) -> str:
    return (
        "Transcribe the receipt image into this exact JSON schema:\n"
        "{"
        '"rawLines": ['
        '{"text": string, "kind": "store|date|item|subtotal|tax|total|payment|metadata|unknown", '
        '"confidence": number}'
        "], "
        '"currencyCandidates": string[], '
        '"dateCandidates": string[], '
        '"totalCandidates": [{"text": string, "amount": number, "confidence": number}], '
        '"warnings": string[]'
        "}\n"
        f"Fallback currency is {currency_code}. "
        "Include unclear lines rather than dropping them. "
        "Classify purchased item rows as item, final paid total rows as total, "
        "and card approval or receipt number rows as metadata/payment."
    )


def _llm_user_prompt(ocr_text: str, currency_code: str) -> str:
    return (
        "Parse this OCR text into JSON with this schema:\n"
        "{"
        '"storeName": string, "amount": number, "date": "YYYY-MM-DD", '
        '"category": "식비|카페|교통|숙박|관광|쇼핑|마트|문화|의료|통신|기타", '
        '"currencyCode": string, "confidence": number, "warnings": string[], '
        '"items": [{"name": string, "translatedName": string, "quantity": number, "unitPrice": number, '
        '"lineTotal": number, "category": string, "confidence": number}]'
        "}\n"
        f"Fallback currency: {currency_code}.\n"
        f"Use currencyCode {currency_code} unless the OCR clearly shows a repeated currency symbol or explicit ISO currency code. "
        "Do not switch currency because of one noisy isolated $, f, e, or o character. "
        "Keep item.name as the original OCR item text, especially for Japanese, Chinese, Thai, "
        "Vietnamese, or European local-language receipts. Put a short Korean meaning in translatedName. "
        "Do not copy OCR_LAYOUT_HINTS lines into warnings; use them only as evidence. "
        "Only include purchased item rows. Exclude store metadata, card approval rows, tax-only rows, "
        "subtotals, payment method rows, and footer text. If quantity is unknown use 1. "
        "If unit price is unknown use lineTotal / quantity. Ignore SKU/barcode/product-code-only lines. "
        "Do not treat product codes, years, gram weights, or receipt numbers as quantity. "
        "If an OCR_LAYOUT_HINTS section is present, use its high-scoring candidates to choose the final total "
        "and reject identifier-like long integers unless they are explicitly on a final total row. "
        "Treat labels such as TOTAL, CELKEM, 합계, 결제금액, and their nearby right-column values as final-total evidence. "
        "When OCR confuses a currency symbol with f/e/o, treat values like f35.00, E0.25, or EO.30 as money. "
        "Prefer the price candidate with a visible currency-like prefix and reject implausible item prices "
        "that would make the item sum exceed the final total. Make item lineTotal values reconcile with "
        "the final paid total whenever the receipt shows clear item prices.\n\n"
        f"OCR text:\n{ocr_text[:6000]}"
    )


def _llm_transcript_user_prompt(transcript: dict[str, Any], currency_code: str) -> str:
    return (
        "Convert this receipt transcript into the app receipt JSON schema:\n"
        "{"
        '"storeName": string, "amount": number, "date": "YYYY-MM-DD", '
        '"category": "식비|카페|교통|숙박|관광|쇼핑|마트|문화|의료|통신|기타", '
        '"currencyCode": string, "confidence": number, "warnings": string[], '
        '"items": [{"name": string, "translatedName": string, "quantity": number, "unitPrice": number, '
        '"lineTotal": number, "category": string, "confidence": number}]'
        "}\n"
        f"Fallback currency: {currency_code}. "
        "Use only transcript lines. Keep item.name as the original transcript text and add "
        "translatedName as a short Korean meaning. Prefer final paid total over subtotal, tax, tendered, "
        "change, or card authorization amount. Include only purchased item rows. "
        "If item sum and receipt total differ, keep the final paid total and add a Korean warning.\n\n"
        f"Transcript JSON:\n{json.dumps(transcript, ensure_ascii=False)[:12000]}"
    )


def _llm_repair_user_prompt(
    payload: dict[str, Any],
    currency_code: str,
    transcript: dict[str, Any] | None,
) -> str:
    amount, item_sum, delta = _receipt_amount_item_delta(payload)
    evidence = (
        json.dumps(transcript, ensure_ascii=False)[:12000]
        if transcript is not None
        else "No transcript is available. Repair using the current JSON only."
    )
    return (
        "Review and repair this receipt JSON. Return the same app schema as JSON only. "
        "Do not invent items. Prefer the final paid total. If the total and item sum cannot "
        "be reconciled from visible evidence, keep the final paid total and add a Korean warning. "
        "Preserve item.name in the original language and keep/add item.translatedName as a short Korean meaning.\n"
        f"Fallback currency: {currency_code}.\n"
        f"Current total: {amount}, item sum: {item_sum}, delta: {delta}.\n"
        f"Current JSON:\n{json.dumps(payload, ensure_ascii=False)[:8000]}\n\n"
        f"Evidence transcript:\n{evidence}"
    )


def _json_object_from_text(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, flags=re.IGNORECASE)
        stripped = re.sub(r"\s*```$", "", stripped)
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start == -1 or end <= start:
            raise HTTPException(status_code=502, detail="LLM did not return JSON")
        try:
            value = json.loads(stripped[start : end + 1])
        except json.JSONDecodeError as exc:
            repaired = _repair_malformed_json_text(stripped)
            if repaired is None:
                raise HTTPException(status_code=502, detail="LLM returned malformed JSON") from exc
            value = repaired
    if not isinstance(value, dict):
        raise HTTPException(status_code=502, detail="LLM JSON response must be an object")
    return value


def _repair_malformed_json_text(text: str) -> dict[str, Any] | None:
    if not settings.receipt_llm_repair_enabled:
        return None
    prompt = (
        "Fix this malformed receipt JSON. Return one valid JSON object only. "
        "Do not add Markdown. Preserve all visible fields and convert nested amount objects "
        "to a numeric amount plus currencyCode when present.\n\n"
        f"Malformed JSON:\n{text[:8000]}"
    )
    try:
        content = _ollama_chat_json_content(
            [
                {"role": "system", "content": _llm_system_prompt()},
                {"role": "user", "content": prompt},
            ],
            error_label="Ollama malformed JSON repair failed",
        )
        stripped = content.strip()
        if stripped.startswith("```"):
            stripped = re.sub(r"^```(?:json)?\s*", "", stripped, flags=re.IGNORECASE)
            stripped = re.sub(r"\s*```$", "", stripped)
        start = stripped.find("{")
        end = stripped.rfind("}")
        candidate = stripped[start : end + 1] if start != -1 and end > start else stripped
        value = json.loads(candidate)
    except (HTTPException, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _clean_ocr_text(text: str) -> str:
    lines: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = re.sub(r"\s+", " ", raw.strip())
        if line:
            lines.append(line)
    return "\n".join(lines)[:12000]


def _prepare_ocr_text_for_parsing(text: str, currency_code: str) -> str:
    if currency_code not in {"JPY", "KRW", "VND"}:
        return text
    return "\n".join(_normalize_zero_decimal_money_line(line) for line in text.splitlines())


def _normalize_zero_decimal_money_line(line: str) -> str:
    money_prefixes = "¥￥半キ"
    if not any(prefix in line for prefix in money_prefixes):
        return line

    def replace(match: re.Match[str]) -> str:
        token = match.group(2)
        normalized = _normalize_zero_decimal_amount_token(token)
        return f"¥{normalized}" if normalized else match.group(0)

    return re.sub(r"([¥￥半キ])\s*([0-9０-９ロOoＳSsフブプばa?,，,.]+)", replace, line)


def _normalize_zero_decimal_amount_token(token: str) -> str:
    table = str.maketrans(
        {
            "０": "0",
            "１": "1",
            "２": "2",
            "３": "3",
            "４": "4",
            "５": "5",
            "６": "6",
            "７": "7",
            "８": "8",
            "９": "9",
            "ロ": "0",
            "O": "0",
            "o": "0",
            "Ｓ": "5",
            "S": "5",
            "s": "5",
            "フ": "7",
            "ブ": "7",
            "プ": "7",
            "ば": "3",
            "a": "3",
            "，": ",",
        }
    )
    text = token.translate(table)
    text = re.sub(r"[^0-9,.]", "", text)
    if not text:
        return ""
    parts = re.split(r"[,.]", text, maxsplit=1)
    if len(parts) == 2:
        head, tail = parts[0], parts[1]
        if not head or not tail:
            return ""
        if len(tail) == 1:
            tail = f"{tail}00"
        elif len(tail) == 2:
            tail = f"{tail}0"
        return f"{head}{tail}"
    if len(text) == 2 and text[0] != "0":
        return f"{text}0"
    return text if len(text) >= 3 else ""


def _mock_ocr_text(currency_code: str) -> str:
    return (
        "TripScript Demo Store\n"
        "2026-05-11\n"
        "Coffee 2 x 4.50\n"
        "Sandwich 1 x 8.00\n"
        f"TOTAL {currency_code} 17.00"
    )


def _guess_store_name(lines: list[str]) -> str:
    for line in lines[:8]:
        markdown_heading = re.sub(r"^#+\s*", "", line).strip()
        if markdown_heading and markdown_heading != line:
            lower_heading = markdown_heading.lower()
            if not _is_metadata_line(markdown_heading):
                return markdown_heading[:80]
        lower = line.lower()
        if _is_metadata_line(line) or _amounts(line):
            continue
        if any(token in line for token in ("ご来店", "ありがとう", "お待ち", "お越し")):
            continue
        if any(token in lower for token in ("tel", "receipt", "invoice", "tax")):
            continue
        return line[:80]
    return lines[0][:80] if lines else ""


def _guess_total(
    lines: list[str],
    amounts_by_line: list[tuple[str, list[float]]],
    candidates: list[float],
) -> float:
    hinted = _hinted_total_amounts(lines, amounts_by_line)
    if hinted:
        return max(hinted)
    return max(candidates) if candidates else 0.0


def _hinted_total_amounts(
    lines: list[str],
    amounts_by_line: list[tuple[str, list[float]]],
) -> list[float]:
    hinted: list[float] = []
    for index, (line, amounts) in enumerate(amounts_by_line):
        if not amounts:
            continue
        lower = line.lower()
        previous = lines[index - 1].lower() if index > 0 else ""
        if _line_has_total_hint(lower) or _line_has_total_hint(previous):
            hinted.extend(
                amount
                for amount in amounts
                if _is_plausible_receipt_amount(amount, line, previous)
            )
    return hinted


def _line_has_total_hint(line: str) -> bool:
    lower = line.lower()
    return any(
        hint in lower
        for hint in (
            "total",
            "amount",
            "합계",
            "총액",
            "결제금액",
            "총 금액",
            "받을금액",
            "받은금액",
            "주문금액",
            "판매금액",
            "발문금액",
            "celkem",
            "celkom",
            "celkova",
            "celková",
            "계;",
            "계:",
            "계 ",
            "合計",
        )
    )


def _line_has_currency_hint(line: str) -> bool:
    return bool(
        re.search(r"[₩원€£$¥]|\b(?:krw|usd|eur|gbp|jpy|chf|cny|sek|nok|dkk|isk|pln|czk|huf)\b", line, re.IGNORECASE)
    )


def _is_amount_candidate_line(line: str, previous: str = "") -> bool:
    if _is_metadata_line(line):
        return False
    if _is_metadata_line(previous) and not (_line_has_total_hint(line) or _line_has_total_hint(previous)):
        return False
    return True


def _is_plausible_receipt_amount(amount: float, line: str, previous: str = "") -> bool:
    if amount <= 0:
        return False
    if amount >= 10_000_000 and not (
        _line_has_total_hint(line)
        or _line_has_total_hint(previous)
        or _line_has_currency_hint(line)
    ):
        return False
    return True


def _guess_items(lines: list[str], total: float, currency_code: str = "KRW") -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    block_items = _guess_block_items(lines, total, currency_code)
    for line in lines:
        lower = line.lower()
        amounts = _amounts(line)
        if not amounts or _is_metadata_line(line):
            continue
        compact_line = re.sub(r"[^A-Za-z0-9]", "", line)
        if re.fullmatch(r"[A-Za-z]{1,5}\d{1,4}", compact_line):
            continue
        if any(hint in lower for hint in ("total", "subtotal", "amount", "tax", "vat", "합계", "총액", "부가세", "결제")):
            continue
        line_total = _line_item_amount(line, amounts)
        if total > 0 and line_total >= total:
            continue
        name = _item_name_from_line(line)
        if len(name) < 2:
            continue
        compact_name = re.sub(r"[^A-Za-z0-9]", "", name)
        if re.fullmatch(r"[A-Za-z]{1,5}\d{1,4}", compact_name):
            continue
        quantity = _quantity_from_line(line)
        unit_price = line_total / quantity if quantity else line_total
        items.append(
            {
                "name": name[:120],
                "translatedName": name[:120],
                "quantity": quantity or 1,
                "unitPrice": round(unit_price, 2),
                "lineTotal": line_total,
                "category": _category_for_name(name),
                "confidence": 0.55,
                "quantityByPerson": {},
            }
        )
    if _items_quality(block_items, total) > _items_quality(items, total):
        return block_items[:80]
    return items[:80]


def _guess_block_items(lines: list[str], total: float, currency_code: str) -> list[dict[str, Any]]:
    if currency_code not in {"JPY", "KRW", "VND"}:
        return []
    items: list[dict[str, Any]] = []
    index = 0
    while index < len(lines) - 1:
        name = lines[index].strip()
        if not _looks_like_item_name_line(name):
            index += 1
            continue

        price_line = lines[index + 1]
        if "¥" not in price_line:
            index += 1
            continue
        amounts = _amounts(price_line)
        if not amounts:
            index += 1
            continue

        quantity = _quantity_from_line(price_line)
        line_total = amounts[-1]
        unit_price = line_total / quantity if quantity else line_total
        consumed = 2

        if len(amounts) >= 2:
            line_total = amounts[-1]
            unit_price = line_total / quantity if quantity else amounts[0]
        elif index + 2 < len(lines) and _quantity_from_line(lines[index + 2]) > 1:
            quantity = _quantity_from_line(lines[index + 2])
            consumed = 3
            if index + 3 < len(lines):
                next_amounts = _amounts(lines[index + 3])
                if next_amounts and next_amounts[-1] >= unit_price * quantity * 0.5:
                    line_total = next_amounts[-1]
                    consumed = 4
                else:
                    line_total = unit_price * quantity
            else:
                line_total = unit_price * quantity

        if total > 0 and (line_total <= 0 or line_total >= total):
            index += 1
            continue

        if quantity > 1:
            unit_price = line_total / quantity

        items.append(
            {
                "name": _item_name_from_line(name)[:120],
                "translatedName": _item_name_from_line(name)[:120],
                "quantity": quantity or 1,
                "unitPrice": round(unit_price, 2),
                "lineTotal": round(line_total, 2),
                "category": _category_for_name(name),
                "confidence": 0.72,
                "quantityByPerson": {},
            }
        )
        index += consumed
    return items


def _looks_like_item_name_line(line: str) -> bool:
    if len(line.strip()) < 2 or _amounts(line) or _is_metadata_line(line):
        return False
    lower = line.lower()
    if re.search(r"\b[xX]\b", line):
        return False
    blocked = (
        "total",
        "subtotal",
        "amount",
        "tax",
        "vat",
        "합계",
        "총액",
        "부가세",
        "결제",
        "商品",
        "小計",
        "消税",
        "消費税",
        "合計",
        "対象",
        "お預り",
        "お釣り",
        "人数",
        "テーブル",
    )
    return not any(token.lower() in lower for token in blocked)


def _items_quality(items: list[dict[str, Any]], total: float) -> float:
    if not items:
        return 0.0
    item_sum = sum(_as_float(item.get("lineTotal")) for item in items)
    score = len(items) * 0.05
    if total > 0:
        score += max(0.0, 1.0 - min(abs(total - item_sum) / total, 1.0))
    return score


def _line_item_amount(line: str, amounts: list[float]) -> float:
    if len(amounts) >= 2 and re.search(r"\d+[.,]\d{2}\s+0?\d\b", line):
        return amounts[-2]
    return amounts[-1]


def _item_name_from_line(line: str) -> str:
    text = re.sub(r"[-+]?\d{1,3}(?:[,\s]\d{3})*(?:[.]\d{1,2})?", " ", line)
    text = re.sub(r"\b\d+\s*(x|X|개|pcs?|ea)\b", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -:|")
    return text


def _quantity_from_line(line: str) -> float:
    match = re.search(r"\b(?:x|X)\s*(\d+(?:[.]\d+)?)\b", line)
    if match:
        return _as_float(match.group(1), 1.0)
    match = re.search(r"(?<!\d)(\d+(?:[.]\d+)?)\s*(?:x|X|개|pcs?|ea)\b", line)
    if match:
        return _as_float(match.group(1), 1.0)
    return 1.0


def _guess_date(lines: list[str]) -> str:
    for line in lines:
        match = re.search(r"(?<!\d)(20\d{2})[-./년 ]+(\d{1,2})[-./월 ]+(\d{1,2})(?!\d)", line)
        if match:
            return _date_from_parts(match.group(1), match.group(2), match.group(3))
        match = re.search(r"(?<!\d)(\d{1,2})[-./](\d{1,2})[-./](20\d{2})(?!\d)", line)
        if match:
            return _date_from_parts(match.group(3), match.group(2), match.group(1))
    return datetime.now().date().isoformat()


def _date_from_parts(year: str, month: str, day: str) -> str:
    try:
        return datetime(int(year), int(month), int(day)).date().isoformat()
    except ValueError:
        return datetime.now().date().isoformat()


def _normalize_date(value: Any) -> str:
    if isinstance(value, str) and value.strip():
        raw = value.strip()
        if "T" in raw:
            raw = raw.split("T", 1)[0]
        raw = raw.replace(".", "-").replace("/", "-")[:10]
        if re.match(r"^\d{4}-\d{1,2}-\d{1,2}$", raw):
            parts = raw.split("-")
            return _date_from_parts(parts[0], parts[1], parts[2])
    return datetime.now().date().isoformat()


def _guess_currency(lines: list[str], fallback: str) -> str:
    text = " ".join(lines).upper()
    fallback_currency = _normalize_currency(fallback)
    if "KRW" in text:
        return "KRW"
    if "EUR" in text:
        return "EUR"
    if "GBP" in text:
        return "GBP"
    if "USD" in text:
        return "USD"
    if "CHF" in text:
        return "CHF"
    if "JPY" in text:
        return "JPY"
    if fallback_currency not in {"KRW", "USD", "EUR", "GBP", "JPY", "CHF"}:
        return fallback_currency
    if "₩" in text or "KRW" in text:
        return "KRW"
    if "€" in text or "EUR" in text:
        return "EUR"
    if "£" in text or "GBP" in text:
        return "GBP"
    if "$" in text or "USD" in text:
        return "USD"
    if "CHF" in text:
        return "CHF"
    if "JPY" in text or "¥" in text:
        return "JPY"
    return fallback_currency


def _guess_category(lines: list[str], items: list[dict[str, Any]]) -> str:
    joined = " ".join(lines + [str(item.get("name") or "") for item in items]).lower()
    if any(token in joined for token in ("coffee", "cafe", "카페", "latte", "americano")):
        return "카페"
    if any(token in joined for token in ("hotel", "hostel", "숙박")):
        return "숙박"
    if any(token in joined for token in ("taxi", "uber", "metro", "bus", "train", "교통")):
        return "교통"
    if any(token in joined for token in ("market", "마트", "grocery", "super")):
        return "마트"
    if any(token in joined for token in ("restaurant", "food", "burger", "pizza", "식당")):
        return "식비"
    return "기타"


def _category_for_name(name: str) -> str:
    return _guess_category([], [{"name": name}])


def _amounts(line: str) -> list[float]:
    values: list[float] = []
    for candidate_line in dict.fromkeys((line, _normalize_ocr_amount_line(line))):
        for match in re.finditer(r"(?<![\d,.])[-+]?\d+[,.]\d{1,2}(?![\d,.])", candidate_line):
            raw = match.group(0).replace(",", ".")
            value = _as_float(raw)
            if value > 0 and value not in values:
                values.append(value)
        for match in re.finditer(r"(?<![\d,.])[-+]?\d{1,3}(?:[,\s]+\d{3})+(?![\d,.])", candidate_line):
            raw = match.group(0).replace(",", "").replace(" ", "")
            value = _as_float(raw)
            if value > 0 and value not in values:
                values.append(value)
        for match in re.finditer(r"(?<![\d,.])[-+]?\d+(?![\d,.])", candidate_line):
            value = _as_float(match.group(0))
            if value > 0 and value not in values:
                values.append(value)
    return values


def _normalize_ocr_amount_line(line: str) -> str:
    translation = str.maketrans(
        {
            "O": "0",
            "o": "0",
            "D": "0",
            "U": "0",
            "u": "0",
            "B": "8",
            "S": "5",
            "s": "5",
            "I": "1",
            "l": "1",
            "|": "1",
        }
    )

    def replace_token(match: re.Match[str]) -> str:
        return match.group(0).translate(translation)

    return re.sub(
        r"(?<![A-Za-z가-힣])(?:[0-9ODUBooslIS|]{1,3}(?:[,\s]+[0-9ODUBooslIS|]{3})+|B[0-9ODUBooslIS|]{3,6})(?=\s*(?:원|₩|krw)?\d?\b|$)",
        replace_token,
        line,
        flags=re.IGNORECASE,
    )


def _is_metadata_line(line: str) -> bool:
    lower = line.lower()
    if lower.lstrip().startswith("#"):
        return True
    return any(
        token in lower
        for token in (
            "tel",
            "phone",
            "address",
            "vat",
            "사업자",
            "대표",
            "승인",
            "approval",
            "auth",
            "card",
            "visa",
            "master",
            "jcb",
            "ticket",
            "till",
            "receipt no",
            "invoice no",
            "www.",
            "http",
        )
    )


def _normalize_currency(value: Any) -> str:
    code = str(value or "KRW").strip().upper()
    return code if re.match(r"^[A-Z]{3}$", code) else "KRW"


def _as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        for key in ("value", "amount", "total", "lineTotal", "price"):
            if key in value:
                return _as_float(value.get(key), default)
        return default
    try:
        return float(str(value).replace(",", "").replace(" ", "").strip())
    except ValueError:
        return default

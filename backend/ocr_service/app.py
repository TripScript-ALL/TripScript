from __future__ import annotations

from io import BytesIO
import os
import re
import tempfile
import threading
import time
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image


MODEL_ID = os.getenv("LIGHTONOCR_MODEL_ID", "lightonai/LightOnOCR-1B-1025")
MAX_NEW_TOKENS = int(os.getenv("LIGHTONOCR_MAX_NEW_TOKENS", "1024"))
PROMPT = os.getenv(
    "LIGHTONOCR_PROMPT",
    (
        "Extract only visible receipt text lines in natural reading order. "
        "Preserve item rows, dates, totals, currencies, and prices. "
        "Do not invent hidden card numbers or repeated filler digits."
    ),
)

app = FastAPI(title="TripScript OCR Service")

_model: Any | None = None
_processor: Any | None = None
_load_error: str | None = None
_lock = threading.Lock()


def _device_dtype() -> tuple[str, Any]:
    import torch

    if torch.cuda.is_available():
        return "cuda", torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    return "cpu", torch.float32


def _load_model() -> tuple[Any, Any]:
    global _load_error, _model, _processor
    if _model is not None and _processor is not None:
        return _model, _processor

    with _lock:
        if _model is not None and _processor is not None:
            return _model, _processor
        try:
            import torch
            from transformers import LightOnOcrForConditionalGeneration, LightOnOcrProcessor

            device, dtype = _device_dtype()
            model_kwargs: dict[str, Any] = {"dtype": dtype}
            if device == "cuda":
                model_kwargs["device_map"] = "auto"

            model = LightOnOcrForConditionalGeneration.from_pretrained(
                MODEL_ID,
                **model_kwargs,
            )
            if device == "cpu":
                model = model.to(device)
            model.eval()
            processor = LightOnOcrProcessor.from_pretrained(MODEL_ID)

            _model = model
            _processor = processor
            _load_error = None
        except Exception as exc:  # pragma: no cover - surfaced through health/readiness.
            _load_error = str(exc)
            raise
    return _model, _processor


def _inputs_for_image(processor: Any, image: Image.Image, image_uri: str, prompt: str) -> Any:
    variants = [
        [{"role": "user", "content": [{"type": "image", "image": image}, {"type": "text", "text": prompt}]}],
        [{"role": "user", "content": [{"type": "image", "url": image_uri}, {"type": "text", "text": prompt}]}],
        [{"role": "user", "content": [{"type": "image", "url": image_uri}]}],
    ]
    last_error: Exception | None = None
    for conversation in variants:
        try:
            return processor.apply_chat_template(
                conversation,
                add_generation_prompt=True,
                tokenize=True,
                return_dict=True,
                return_tensors="pt",
            )
        except Exception as exc:
            last_error = exc

    try:
        return processor(images=image, text=prompt, return_tensors="pt")
    except Exception as exc:
        raise RuntimeError(f"LightOnOCR processor failed: {last_error or exc}") from exc


def _to_device(inputs: Any, model: Any) -> Any:
    try:
        return inputs.to(model.device)
    except Exception:
        return inputs


def _decode_generated(processor: Any, output_ids: Any, inputs: Any) -> str:
    input_length = 0
    try:
        input_length = int(inputs["input_ids"].shape[1])
    except Exception:
        input_length = 0
    generated_ids = output_ids[0, input_length:] if input_length else output_ids[0]
    return str(processor.decode(generated_ids, skip_special_tokens=True)).strip()


def _trim_repeated_digit_noise(text: str) -> str:
    text = re.sub(r"([0-9])\1{23,}", "[redacted repeated digits]", text)
    lines = []
    for line in text.splitlines():
        compact = re.sub(r"\s+", "", line)
        if len(compact) >= 40 and compact.count("0") / max(1, len(compact)) > 0.85:
            continue
        lines.append(line.rstrip())
    return "\n".join(lines).strip()


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok" if _load_error is None else "degraded",
        "modelId": MODEL_ID,
        "loaded": _model is not None,
        "loadError": _load_error,
    }


@app.post("/ocr")
async def ocr(file: UploadFile = File(...), prompt: str | None = None) -> dict[str, Any]:
    started = time.perf_counter()
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty image file")

    try:
        image = Image.open(BytesIO(raw)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image file: {exc}") from exc

    try:
        model, processor = _load_model()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"LightOnOCR model load failed: {exc}") from exc

    suffix = os.path.splitext(file.filename or "")[1] or ".jpg"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
        tmp.write(raw)
        tmp.flush()
        inputs = _inputs_for_image(processor, image, f"file://{tmp.name}", prompt or PROMPT)

    try:
        import torch

        with _lock, torch.inference_mode():
            inputs = _to_device(inputs, model)
            output_ids = model.generate(
                **inputs,
                max_new_tokens=MAX_NEW_TOKENS,
                do_sample=False,
                pad_token_id=getattr(processor.tokenizer, "eos_token_id", None),
                eos_token_id=getattr(processor.tokenizer, "eos_token_id", None),
            )
            text = _trim_repeated_digit_noise(_decode_generated(processor, output_ids, inputs))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LightOnOCR inference failed: {exc}") from exc

    elapsed_ms = int(round((time.perf_counter() - started) * 1000))
    return {
        "text": text,
        "metadata": {
            "provider": "lightonocr_service",
            "model": MODEL_ID,
            "durationMs": elapsed_ms,
            "durationSeconds": round(elapsed_ms / 1000, 2),
            "imageWidth": image.width,
            "imageHeight": image.height,
        },
    }

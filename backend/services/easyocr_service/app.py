from __future__ import annotations

from functools import lru_cache
import time
from typing import Any

import cv2
import easyocr
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
import numpy as np


app = FastAPI(title="TripScript EasyOCR Service")

MAX_EDGE = 1344


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ocr")
async def ocr(
    file: UploadFile = File(...),
    currencyCode: str = Form("KRW"),
    preprocess: str = Form("safe"),
) -> dict[str, Any]:
    started = time.perf_counter()
    raw = await file.read()
    image = _decode_image(raw)
    if image is None:
        raise HTTPException(status_code=422, detail="Invalid image file")

    langs = _langs_for_currency(currencyCode)
    preprocess_mode = (preprocess or "safe").strip().lower()
    if preprocess_mode == "flatten":
        flattened = _flatten_receipt(image)
        if flattened is not None:
            image = flattened
    image = _resize_image(image, MAX_EDGE)
    image_height, image_width = image.shape[:2]
    reader, init_ms = _reader_for_langs(tuple(langs))
    try:
        rows = reader.readtext(image, detail=1, paragraph=False)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"EasyOCR failed: {exc}") from exc

    layout_lines = _layout_lines(rows)
    lines = [line["text"] for line in layout_lines if line["text"]]
    elapsed_ms = int(round((time.perf_counter() - started) * 1000))
    return {
        "text": "\n".join(lines),
        "metadata": {
            "provider": "easyocr_service",
            "langs": langs,
            "lineCount": len(lines),
            "durationMs": elapsed_ms,
            "durationSeconds": round(elapsed_ms / 1000, 2),
            "readerInitMs": init_ms,
            "maxEdge": MAX_EDGE,
            "preprocess": preprocess_mode,
            "imageWidth": image_width,
            "imageHeight": image_height,
            "layoutLines": layout_lines,
        },
    }


def _decode_image(raw: bytes) -> Any | None:
    source = np.frombuffer(raw, dtype=np.uint8)
    return cv2.imdecode(source, cv2.IMREAD_COLOR)


def _resize_image(image: Any, max_edge: int) -> Any:
    height, width = image.shape[:2]
    longest = max(width, height)
    if longest <= max_edge:
        return image
    scale = max_edge / float(longest)
    return cv2.resize(
        image,
        (max(1, int(width * scale)), max(1, int(height * scale))),
        interpolation=cv2.INTER_AREA,
    )


def _layout_lines(rows: list[Any]) -> list[dict[str, Any]]:
    parsed: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, (list, tuple)) or len(row) < 2:
            continue
        box = row[0]
        text = str(row[1] or "").strip()
        if not text:
            continue
        confidence = float(row[2]) if len(row) >= 3 and isinstance(row[2], (int, float)) else None
        points = _box_points(box)
        if not points:
            continue
        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        parsed.append(
            {
                "text": text,
                "confidence": round(confidence, 4) if confidence is not None else None,
                "bbox": [[round(x, 2), round(y, 2)] for x, y in points],
                "xMin": round(min(xs), 2),
                "yMin": round(min(ys), 2),
                "xMax": round(max(xs), 2),
                "yMax": round(max(ys), 2),
                "xCenter": round(sum(xs) / len(xs), 2),
                "yCenter": round(sum(ys) / len(ys), 2),
            }
        )
    return sorted(parsed, key=lambda line: (line["yCenter"], line["xCenter"]))


def _box_points(box: Any) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    if not isinstance(box, (list, tuple)):
        return points
    for point in box:
        if not isinstance(point, (list, tuple)) or len(point) < 2:
            continue
        try:
            points.append((float(point[0]), float(point[1])))
        except (TypeError, ValueError):
            continue
    return points


def _flatten_receipt(image: Any) -> Any | None:
    normalized = _normalize_image_size(image)
    warped = _perspective_receipt_crop(normalized)
    if warped is None:
        return _enhance_receipt(normalized)
    return _enhance_receipt(warped)


def _normalize_image_size(image: Any) -> Any:
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


def _perspective_receipt_crop(image: Any) -> Any | None:
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
        ordered = _order_points(points)
        warped = _four_point_transform(image, ordered)
        if warped is not None:
            return warped
    return None


def _order_points(points: Any) -> Any:
    rect = np.zeros((4, 2), dtype="float32")
    sums = points.sum(axis=1)
    diffs = np.diff(points, axis=1)
    rect[0] = points[np.argmin(sums)]
    rect[2] = points[np.argmax(sums)]
    rect[1] = points[np.argmin(diffs)]
    rect[3] = points[np.argmax(diffs)]
    return rect


def _four_point_transform(image: Any, points: Any) -> Any | None:
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


def _enhance_receipt(image: Any) -> Any:
    try:
        lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
        lightness, channel_a, channel_b = cv2.split(lab)
        clahe = cv2.createCLAHE(clipLimit=1.8, tileGridSize=(8, 8))
        lightness = clahe.apply(lightness)
        enhanced = cv2.merge((lightness, channel_a, channel_b))
        return cv2.cvtColor(enhanced, cv2.COLOR_LAB2BGR)
    except Exception:
        return image


def _langs_for_currency(currency_code: str) -> list[str]:
    code = (currency_code or "").strip().upper()
    if code == "KRW":
        return ["ko", "en"]
    if code == "JPY":
        return ["ja", "en"]
    return ["en"]


@lru_cache(maxsize=4)
def _reader_for_langs(langs: tuple[str, ...]) -> tuple[easyocr.Reader, int]:
    started = time.perf_counter()
    reader = easyocr.Reader(list(langs), gpu=False, verbose=False)
    init_ms = int(round((time.perf_counter() - started) * 1000))
    return reader, init_ms

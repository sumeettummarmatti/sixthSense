"""Transient image comparison through the local CompreFace installation."""

from typing import Any

import httpx

from app.core.config import Settings


class FaceMatchError(Exception):
    """The local face matcher could not produce a safe comparison result."""

    def __init__(self, code: str = "face_match_unavailable") -> None:
        super().__init__(code)
        self.code = code


def _upload_filename(prefix: str, image_type: str) -> str:
    extension = {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
    }.get(image_type)
    if extension is None:
        raise FaceMatchError("unsupported face image type")
    return f"{prefix}.{extension}"


def compare_faces(
    settings: Settings,
    *,
    id_image: bytes,
    id_image_type: str,
    selfie_image: bytes,
    selfie_image_type: str,
) -> float:
    if not settings.compreface_api_key:
        raise FaceMatchError("face matcher is not configured")

    try:
        response = httpx.post(
            f"{settings.compreface_api_url.rstrip('/')}/api/v1/verification/verify",
            headers={"x-api-key": settings.compreface_api_key},
            files={
                "source_image": (
                    _upload_filename("id-image", id_image_type),
                    id_image,
                    id_image_type,
                ),
                "target_image": (
                    _upload_filename("selfie", selfie_image_type),
                    selfie_image,
                    selfie_image_type,
                ),
            },
            timeout=30.0,
        )
        response.raise_for_status()
        payload: Any = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        # Do not include image data, provider response bodies, or document details in logs.
        raise FaceMatchError("face matcher request failed") from exc

    results = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        raise FaceMatchError()
    if len(results) != 1:
        raise FaceMatchError("face_image_invalid")
    matches = results[0].get("face_matches")
    if not isinstance(matches, list):
        raise FaceMatchError()
    if len(matches) != 1:
        raise FaceMatchError("face_image_invalid")
    similarity = matches[0].get("similarity")
    if not isinstance(similarity, (int, float)) or not 0.0 <= similarity <= 1.0:
        raise FaceMatchError("matcher returned an invalid score")
    return float(similarity)

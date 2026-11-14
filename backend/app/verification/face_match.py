"""Transient image comparison through the local CompreFace installation."""

from dataclasses import dataclass
from math import isfinite
from typing import Any

import httpx

from app.core.config import Settings

# CompreFace only returns plugins_versions (needed to keep a face template) with status=true.
_TEMPLATE_PARAMS = {"face_plugins": "calculator", "status": "true"}


class FaceMatchError(Exception):
    """The local face matcher could not produce a safe comparison result."""

    def __init__(self, code: str = "face_match_unavailable") -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class FaceComparison:
    similarity: float
    source_embedding: list[float] | None = None  # the ID photo's face
    calculator_version: str | None = None
    target_embedding: list[float] | None = None  # the live selfie's face (ban-list check)


def _valid_embedding(value: Any) -> bool:
    return (
        isinstance(value, list)
        and 1 <= len(value) <= 2048
        and all(isinstance(v, (int, float)) and isfinite(v) for v in value)
    )


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
    capture_template: bool = False,
) -> float | FaceComparison:
    if settings.face_matcher == "mock":
        # DEV ONLY (FACE_MATCHER=mock, refused outside dev/test): no CompreFace on this machine.
        # Every ID photo/selfie pair "matches"; no face template is produced.
        return 1.0
    if not settings.compreface_api_key:
        raise FaceMatchError("face matcher is not configured")

    try:
        response = httpx.post(
            f"{settings.compreface_api_url.rstrip('/')}/api/v1/verification/verify",
            params=_TEMPLATE_PARAMS if capture_template else None,
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
    if not capture_template:
        return float(similarity)
    source = results[0].get("source_image_face")
    embedding = source.get("embedding") if isinstance(source, dict) else None
    versions = results[0].get("plugins_versions")
    version = versions.get("calculator") if isinstance(versions, dict) else None
    if not _valid_embedding(embedding) or not isinstance(version, str) or not version:
        raise FaceMatchError("face_template_unavailable")
    selfie = matches[0].get("embedding")
    return FaceComparison(
        float(similarity),
        [float(value) for value in embedding],
        version,
        [float(value) for value in selfie] if _valid_embedding(selfie) else None,
    )


def best_embedding_match(
    settings: Settings, embedding: list[float], targets: list[list[float]]
) -> float:
    """Highest similarity between one face embedding and a list of stored ones (0 if none)."""
    if not targets:
        return 0.0
    if not settings.compreface_api_key:
        raise FaceMatchError("face matcher is not configured")
    try:
        response = httpx.post(
            f"{settings.compreface_api_url.rstrip('/')}/api/v1/verification/embeddings/verify",
            headers={"x-api-key": settings.compreface_api_key},
            json={"source": embedding, "targets": targets},
            timeout=30.0,
        )
        response.raise_for_status()
        payload: Any = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise FaceMatchError("face matcher request failed") from exc
    results = payload.get("result") if isinstance(payload, dict) else None
    scores = [r.get("similarity") for r in results] if isinstance(results, list) else []
    if not scores or any(
        not isinstance(x, (int, float)) or not isfinite(x) or not 0.0 <= x <= 1.0 for x in scores
    ):
        raise FaceMatchError()
    return float(max(scores))


def compare_template_to_selfie(
    settings: Settings,
    *,
    template_embedding: list[float],
    calculator_version: str,
    selfie_image: bytes,
    selfie_image_type: str,
) -> float:
    if not settings.compreface_api_key:
        raise FaceMatchError("face matcher is not configured")
    try:
        # Verification service supports the calculator plugin; duplicating the fresh selfie
        # yields its embedding without persisting or registering the source image in CompreFace.
        image_response = httpx.post(
            f"{settings.compreface_api_url.rstrip('/')}/api/v1/verification/verify",
            params=_TEMPLATE_PARAMS,
            headers={"x-api-key": settings.compreface_api_key},
            files={
                "source_image": (
                    _upload_filename("walk-selfie-source", selfie_image_type),
                    selfie_image,
                    selfie_image_type,
                ),
                "target_image": (
                    _upload_filename("walk-selfie-target", selfie_image_type),
                    selfie_image,
                    selfie_image_type,
                ),
            },
            timeout=30.0,
        )
        image_response.raise_for_status()
        payload: Any = image_response.json()
        result = payload.get("result") if isinstance(payload, dict) else None
        if not isinstance(result, list) or len(result) != 1:
            raise FaceMatchError("face_image_invalid")
        face = result[0].get("source_image_face")
        embedding = face.get("embedding") if isinstance(face, dict) else None
        versions = result[0].get("plugins_versions")
        version = versions.get("calculator") if isinstance(versions, dict) else None
        matches = result[0].get("face_matches")
        if (
            not isinstance(matches, list)
            or len(matches) != 1
            or not isinstance(embedding, list)
            or not 1 <= len(embedding) <= 2048
            or any(
                not isinstance(value, (int, float)) or not isfinite(value) for value in embedding
            )
            or version != calculator_version
        ):
            code = (
                "face_image_invalid"
                if version == calculator_version
                else "face_template_model_changed"
            )
            raise FaceMatchError(code)
        verify_response = httpx.post(
            f"{settings.compreface_api_url.rstrip('/')}/api/v1/verification/embeddings/verify",
            headers={"x-api-key": settings.compreface_api_key},
            json={"source": template_embedding, "targets": [[float(value) for value in embedding]]},
            timeout=30.0,
        )
        verify_response.raise_for_status()
        verify_payload: Any = verify_response.json()
    except FaceMatchError:
        raise
    except (httpx.HTTPError, ValueError) as exc:
        raise FaceMatchError("face matcher request failed") from exc
    results = verify_payload.get("result") if isinstance(verify_payload, dict) else None
    score = (
        results[0].get("similarity") if isinstance(results, list) and len(results) == 1 else None
    )
    if not isinstance(score, (int, float)) or not isfinite(score) or not 0.0 <= score <= 1.0:
        raise FaceMatchError()
    return float(score)

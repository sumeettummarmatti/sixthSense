import pytest

from app.core.config import Settings
from app.verification.face_match import FaceMatchError, compare_faces


def test_compreface_compares_transient_id_and_selfie(monkeypatch) -> None:
    captured = {}

    class Response:
        def raise_for_status(self) -> None:
            pass

        def json(self) -> dict:
            return {"result": [{"face_matches": [{"similarity": 0.91}]}]}

    def post(url, **kwargs):
        captured["url"] = url
        captured.update(kwargs)
        return Response()

    monkeypatch.setattr("app.verification.face_match.httpx.post", post)
    settings = Settings(compreface_api_url="http://matcher:8000", compreface_api_key="test-key")
    score = compare_faces(
        settings,
        id_image=b"id bytes",
        id_image_type="image/png",
        selfie_image=b"selfie bytes",
        selfie_image_type="image/jpeg",
    )
    assert score == 0.91
    assert captured["url"] == "http://matcher:8000/api/v1/verification/verify"
    assert captured["headers"] == {"x-api-key": "test-key"}
    assert captured["files"]["source_image"] == (
        "id-image.png",
        b"id bytes",
        "image/png",
    )
    assert captured["files"]["target_image"] == (
        "selfie.jpg",
        b"selfie bytes",
        "image/jpeg",
    )


def test_compreface_fails_closed_without_service_key() -> None:
    settings = Settings(compreface_api_key="")
    with pytest.raises(FaceMatchError):
        compare_faces(
            settings,
            id_image=b"id",
            id_image_type="image/jpeg",
            selfie_image=b"selfie",
            selfie_image_type="image/jpeg",
        )


def test_compreface_rejects_ambiguous_face_result(monkeypatch) -> None:
    class Response:
        def raise_for_status(self) -> None:
            pass

        def json(self) -> dict:
            return {
                "result": [
                    {"face_matches": [{"similarity": 0.9}, {"similarity": 0.2}]}
                ]
            }

    monkeypatch.setattr("app.verification.face_match.httpx.post", lambda *a, **k: Response())
    with pytest.raises(FaceMatchError) as error:
        compare_faces(
            Settings(compreface_api_key="test-key"),
            id_image=b"id",
            id_image_type="image/jpeg",
            selfie_image=b"selfie",
            selfie_image_type="image/jpeg",
        )
    assert error.value.code == "face_image_invalid"


def test_compreface_reports_missing_face_as_invalid_input(monkeypatch) -> None:
    class Response:
        def raise_for_status(self) -> None:
            pass

        def json(self) -> dict:
            return {"result": []}

    monkeypatch.setattr("app.verification.face_match.httpx.post", lambda *a, **k: Response())
    with pytest.raises(FaceMatchError) as error:
        compare_faces(
            Settings(compreface_api_key="test-key"),
            id_image=b"id",
            id_image_type="image/jpeg",
            selfie_image=b"selfie",
            selfie_image_type="image/jpeg",
        )
    assert error.value.code == "face_image_invalid"

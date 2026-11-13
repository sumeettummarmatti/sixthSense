import io
import logging

import pytest

from app.core.logging import PIIScrubFilter, configure_logging, scrub


@pytest.mark.parametrize(
    ("raw", "leaked"),
    [
        ("call +91 9876543210 now", "9876543210"),
        ("call 09876543210", "9876543210"),
        ("number 9876543210", "9876543210"),
        ("mail priya@example.com", "priya@example.com"),
        ("aadhaar 1234 5678 9012", "1234 5678 9012"),
        ("aadhaar 123456789012", "123456789012"),
        ("at 12.971599, 77.594566", "12.971599"),
    ],
)
def test_scrub_redacts(raw: str, leaked: str) -> None:
    assert leaked not in scrub(raw)


def test_scrub_keeps_harmless_text() -> None:
    assert scrub("journey 42 moved to ContactAlert") == "journey 42 moved to ContactAlert"


def test_filter_redacts_args() -> None:
    record = logging.LogRecord("t", logging.INFO, __file__, 1, "user %s", ("9876543210",), None)
    PIIScrubFilter().filter(record)
    assert "9876543210" not in record.getMessage()


def test_uvicorn_access_log_is_scrubbed() -> None:
    """A route request line carries start and destination in its query string."""
    configure_logging()
    access = logging.getLogger("uvicorn.access")
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)  # stands in for uvicorn's own access handler
    access.addHandler(handler)
    try:
        access.info(
            '%s - "%s %s HTTP/%s" %d',
            "127.0.0.1:1234",
            "GET",
            "/routes?from=12.9719,77.6412&to=12.9610,77.6390&at=night",
            "1.1",
            200,
        )
    finally:
        access.removeHandler(handler)
    text = stream.getvalue()
    assert "12.9719" not in text and "77.6390" not in text
    assert "REDACTED_COORDS" in text and "GET" in text


def test_url_encoded_coordinates_are_scrubbed() -> None:
    """Real clients send the comma as %2C: /routes?from=12.9719%2C77.6412."""
    line = "/routes?from=12.9719%2C77.6412&to=12.9610%2c77.6390&at=night"
    assert scrub(line) == "/routes?from=[REDACTED_COORDS]&to=[REDACTED_COORDS]&at=night"

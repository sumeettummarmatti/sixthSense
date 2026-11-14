import logging

import pytest

from app.core.logging import PIIScrubFilter, scrub


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


def test_url_encoded_coordinates_are_scrubbed() -> None:
    from app.core.logging import scrub

    assert scrub("/x?at=12.9719%2C77.6412") == "/x?at=[REDACTED_COORDS]"

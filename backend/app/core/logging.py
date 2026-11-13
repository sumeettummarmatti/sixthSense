"""Logging that never logs personal data.

Every log record passes through PIIScrubFilter, which redacts phone numbers, emails,
Aadhaar-like 12-digit numbers and lat/lng coordinate pairs before anything is emitted.
This is a safety net, not a licence to log personal data: modules should still avoid it.
"""

import logging
import re

_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # lat,lng pairs like 12.9716, 77.5946 (checked before phone numbers)
    # The separator may be URL-encoded (%2C) in request lines, e.g. /routes?from=12.97%2C77.64.
    (re.compile(r"-?\d{1,3}\.\d{3,}\s*(?:,|%2[cC])\s*-?\d{1,3}\.\d{3,}"), "[REDACTED_COORDS]"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "[REDACTED_EMAIL]"),
    # Aadhaar-like: 12 digits, optionally grouped 4-4-4
    (re.compile(r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"), "[REDACTED_ID]"),
    # Indian mobile numbers, with optional +91 / 0 prefix
    (re.compile(r"(?:\+91[\s-]?|\b0|\b)[6-9]\d{9}\b"), "[REDACTED_PHONE]"),
]


def scrub(text: str) -> str:
    for pattern, replacement in _PATTERNS:
        text = pattern.sub(replacement, text)
    return text


class PIIScrubFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = scrub(record.getMessage())
        record.args = None
        return True


def configure_logging(level: int = logging.INFO) -> None:
    handler = logging.StreamHandler()
    handler.addFilter(PIIScrubFilter())
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

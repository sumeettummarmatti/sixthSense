"""Evidence-aware labels. There is deliberately NO 'safe' label (rule 5).

A quiet street with no reports is not safe, it is unknown.
"""

from enum import StrEnum


class RiskLabel(StrEnum):
    STRONG_EVIDENCE = "Strong evidence of concern"
    SOME_REPORTS = "Some reports of concern"
    INSUFFICIENT_DATA = "Insufficient data"


def is_publishable(
    report_count: int, device_count: int, min_reports: int, min_devices: int
) -> bool:
    """k/m threshold: hide a cluster until it has >= k reports from >= m distinct devices."""
    return report_count >= min_reports and device_count >= min_devices

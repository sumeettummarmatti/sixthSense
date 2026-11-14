"""Verification provider adapters. The mock never persists document data."""

from dataclasses import dataclass
from datetime import date
from typing import Protocol


@dataclass(frozen=True)
class ProviderResult:
    status: str
    reason_code: str | None = None
    is_adult: bool = False


class VerificationProvider(Protocol):
    def verify(self, id_type: str, id_number: str, date_of_birth: date) -> ProviderResult: ...


class MockProvider:
    SCENARIOS = {
        "approve",
        "reject_doc",
        "reject_face",
        "liveness_fail",
        "underage",
        "provider_error",
    }

    def __init__(self, scenarios_enabled: bool = False, scenario: str | None = None):
        self.scenarios_enabled = scenarios_enabled
        self.scenario = scenario if scenarios_enabled and scenario in self.SCENARIOS else "approve"

    def verify(self, id_type: str, id_number: str, date_of_birth: date) -> ProviderResult:
        # Inputs are intentionally consumed only in memory; callers retain only keyed HMACs.
        _ = id_type, id_number
        if self.scenario == "provider_error":
            raise RuntimeError("verification_provider_error")
        if self.scenario in {"reject_doc", "reject_face", "liveness_fail"}:
            return ProviderResult("rejected", self.scenario)
        age = (
            date.today().year
            - date_of_birth.year
            - ((date.today().month, date.today().day) < (date_of_birth.month, date_of_birth.day))
        )
        adult = age >= 18
        if self.scenario == "underage" or not adult:
            return ProviderResult("underage", "underage", False)
        return ProviderResult("verified", is_adult=True)


class CampusOfficeProvider:
    def verify(self, id_type: str, id_number: str, date_of_birth: date) -> ProviderResult:
        """Campus staff must verify the person in person; no automated approval."""
        _ = id_type, id_number, date_of_birth
        return ProviderResult("pending")


class SetuProvider:
    def verify(self, id_type: str, id_number: str, date_of_birth: date) -> ProviderResult:
        """TODO: Setu OCR -> document verification -> liveness -> face match."""
        _ = id_type, id_number, date_of_birth
        raise NotImplementedError("Setu verification is not configured")

"""Deterministic severity classification (never delegated to the model)."""

from __future__ import annotations

from .models import Category, Severity, Signal

_BASE = {
    Category.NO_HEALTHY_TARGETS: Severity.SEV1,
    Category.APPLICATION_ERRORS: Severity.SEV2,
    Category.UNHEALTHY_TARGETS: Severity.SEV2,
    Category.TASK_STOPPED: Severity.SEV3,
    Category.HIGH_CPU: Severity.SEV3,
    Category.HIGH_MEMORY: Severity.SEV3,
    Category.UNKNOWN: Severity.SEV4,
}

_ORDER = [Severity.SEV1, Severity.SEV2, Severity.SEV3, Severity.SEV4]


def classify(signal: Signal, evidence: dict) -> Severity:
    severity = _BASE.get(signal.category, Severity.SEV4)
    # Escalate one level when the evidence shows no healthy targets left behind the ALB.
    targets = evidence.get("target_health", {})
    if isinstance(targets, dict) and targets.get("total", 0) > 0 and targets.get("healthy", 0) == 0:
        idx = max(0, _ORDER.index(severity) - 1)
        severity = _ORDER[idx]
    return severity

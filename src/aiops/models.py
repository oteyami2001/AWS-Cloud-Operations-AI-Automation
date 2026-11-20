"""Domain models shared by every Lambda function."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from enum import Enum
from typing import Any


def utcnow() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


class Severity(str, Enum):
    SEV1 = "SEV1"  # customer-facing outage
    SEV2 = "SEV2"  # major degradation
    SEV3 = "SEV3"  # minor degradation / early warning
    SEV4 = "SEV4"  # informational


class IncidentStatus(str, Enum):
    OPEN = "OPEN"  # detected, analysed, waiting for a human
    REMEDIATION_REQUESTED = "REMEDIATION_REQUESTED"  # a human approved a runbook
    REMEDIATING = "REMEDIATING"  # SSM Automation running
    RESOLVED = "RESOLVED"  # recovered (alarm OK or runbook success)
    REMEDIATION_FAILED = "REMEDIATION_FAILED"
    REJECTED = "REJECTED"  # human declined the recommendation; incident stays tracked


OPEN_STATUSES = {
    IncidentStatus.OPEN.value,
    IncidentStatus.REMEDIATION_REQUESTED.value,
    IncidentStatus.REMEDIATING.value,
    IncidentStatus.REMEDIATION_FAILED.value,
    IncidentStatus.REJECTED.value,
}


class Category(str, Enum):
    UNHEALTHY_TARGETS = "UNHEALTHY_TARGETS"
    NO_HEALTHY_TARGETS = "NO_HEALTHY_TARGETS"
    APPLICATION_ERRORS = "APPLICATION_ERRORS"
    HIGH_CPU = "HIGH_CPU"
    HIGH_MEMORY = "HIGH_MEMORY"
    TASK_STOPPED = "TASK_STOPPED"
    UNKNOWN = "UNKNOWN"


@dataclass
class Signal:
    """A normalised detection signal derived from an EventBridge event."""

    source: str  # e.g. "cloudwatch-alarm", "ecs-task"
    name: str  # alarm name or task ARN
    state: str  # ALARM / OK / STOPPED
    category: Category
    reason: str
    region: str
    account: str
    timestamp: str
    resource: dict[str, str] = field(default_factory=dict)  # cluster, service, target_group ...
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def dedupe_key(self) -> str:
        scope = self.resource.get("service") or self.resource.get("target_group") or self.name
        return f"{self.category.value}#{scope}"


@dataclass
class Analysis:
    summary: str
    probable_cause: str
    confidence: str  # low | medium | high
    troubleshooting_steps: list[str]
    recommended_runbook: str  # an id from runbooks.CATALOG, or "NONE"
    rationale: str
    engine: str  # "bedrock:<model>" or "rules"
    evidence_refs: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class Incident:
    incident_id: str
    dedupe_key: str
    title: str
    category: str
    severity: str
    status: str
    created_at: str
    updated_at: str
    resource: dict[str, str]
    signal: dict[str, Any]
    evidence: dict[str, Any]
    analysis: dict[str, Any]
    history: list[dict[str, Any]] = field(default_factory=list)
    remediation: dict[str, Any] = field(default_factory=dict)
    resolved_at: str | None = None

    @staticmethod
    def new_id() -> str:
        return "INC-" + datetime.now(UTC).strftime("%Y%m%d") + "-" + uuid.uuid4().hex[:8]

    def add_history(self, action: str, actor: str, detail: str = "") -> None:
        ts = utcnow()
        self.history.append({"at": ts, "action": action, "actor": actor, "detail": detail})
        self.updated_at = ts

    def to_item(self) -> dict[str, Any]:
        item = asdict(self)
        if item["resolved_at"] is None:
            item.pop("resolved_at")
        return item

    @classmethod
    def from_item(cls, item: dict[str, Any]) -> Incident:
        fields = {f for f in cls.__dataclass_fields__}  # type: ignore[attr-defined]
        return cls(**{k: v for k, v in item.items() if k in fields})

"""Remediation Status Lambda - records SSM Automation outcomes on the incident.

Triggered by EventBridge "EC2 Automation Execution Status-change Notification" events.
"""

from __future__ import annotations

import logging
from typing import Any

import boto3

from ..models import IncidentStatus, utcnow
from ..platform import Config, Notifier, emit_metric
from ..store import IncidentStore

log = logging.getLogger()
log.setLevel(logging.INFO)

TERMINAL_OK = {"Success"}
TERMINAL_FAIL = {"Failed", "TimedOut", "Cancelled", "Rejected", "CompletedWithFailure"}


class StatusService:
    def __init__(self, store: IncidentStore, notifier: Notifier):
        self.store = store
        self.notifier = notifier

    def handle(self, event: dict[str, Any]) -> dict[str, Any]:
        detail = event.get("detail", {})
        execution_id = detail.get("ExecutionId") or detail.get("AutomationExecutionId", "")
        status = detail.get("Status", "")
        incident = self.store.find_by_execution(execution_id) if execution_id else None
        if not incident:
            return {"action": "ignored", "reason": f"no incident for execution {execution_id}"}

        if status in TERMINAL_OK:
            incident.status = IncidentStatus.RESOLVED.value
            incident.resolved_at = incident.resolved_at or utcnow()
            incident.add_history("REMEDIATION_SUCCEEDED", "ssm", f"execution {execution_id} {status}")
        elif status in TERMINAL_FAIL:
            incident.status = IncidentStatus.REMEDIATION_FAILED.value
            incident.add_history("REMEDIATION_FAILED", "ssm", f"execution {execution_id} {status}")
        else:
            incident.add_history("REMEDIATION_PROGRESS", "ssm", f"execution {execution_id} {status}")
        incident.remediation = {**incident.remediation, "final_status": status}
        self.store.put(incident)
        emit_metric("RemediationOutcome", 1, Status=status or "Unknown")
        if status in TERMINAL_OK | TERMINAL_FAIL:
            self.notifier.publish(
                f"Remediation {status}: {incident.incident_id}",
                {"incident_id": incident.incident_id, "status": incident.status},
            )
        return {"action": "updated", "incident_id": incident.incident_id, "status": incident.status}


_service: StatusService | None = None


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # pragma: no cover
    global _service
    if _service is None:
        cfg = Config.from_env()
        session = boto3.session.Session()
        _service = StatusService(
            IncidentStore(session.resource("dynamodb").Table(cfg.table_name)),
            Notifier(session.client("sns"), cfg.topic_arn),
        )
    return _service.handle(event)

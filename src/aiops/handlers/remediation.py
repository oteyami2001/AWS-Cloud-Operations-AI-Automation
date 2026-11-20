"""Remediation Approval Lambda (Lambda Function URL, auth type AWS_IAM).

The ONLY component allowed to call ``ssm:StartAutomationExecution``, and only on the
approved runbook documents. A human calls it with a SigV4-signed request
(``scripts/approve.py``); the approver identity comes from the verified IAM caller ARN in
``requestContext.authorizer.iam``, never from the request body.

Gates, in order:
1. Caller authenticated by IAM (Function URL AWS_IAM + resource policy) - enforced by AWS.
2. Caller ARN matches an approver prefix (APPROVER_ARN_PREFIXES).
3. Incident exists and is in an actionable status.
4. Runbook is in the approved catalog AND was the recommendation (or an explicit override that is
   still in the catalog and valid for the incident category).
5. Parameters are built from the incident's trusted resource ids - not from the request or the AI.
6. HIGH-risk runbooks pause inside SSM on an ``aws:approve`` step for a second approval.
"""

from __future__ import annotations

import base64
import json
import logging
from typing import Any

import boto3

from ..models import Category, IncidentStatus
from ..platform import Config, Notifier, emit_metric
from ..runbooks import CATALOG, NONE
from ..store import IncidentStore

log = logging.getLogger()
log.setLevel(logging.INFO)

ACTIONABLE = {IncidentStatus.OPEN.value, IncidentStatus.REMEDIATION_FAILED.value, IncidentStatus.REJECTED.value}


class ApprovalError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def caller_arn(event: dict[str, Any]) -> str:
    iam = event.get("requestContext", {}).get("authorizer", {}).get("iam", {})
    arn = iam.get("userArn") or iam.get("callerArn") or ""
    if not arn:
        raise ApprovalError(401, "request is not IAM-authenticated")
    return arn


def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        data = json.loads(body)
    except ValueError as exc:
        raise ApprovalError(400, "body must be JSON") from exc
    if not isinstance(data, dict):
        raise ApprovalError(400, "body must be a JSON object")
    return data


class RemediationService:
    def __init__(self, config: Config, store: IncidentStore, ssm: Any, notifier: Notifier):
        self.config = config
        self.store = store
        self.ssm = ssm
        self.notifier = notifier

    def handle(self, event: dict[str, Any]) -> dict[str, Any]:
        try:
            result = self._handle(event)
            return _response(200, result)
        except ApprovalError as exc:
            log.warning("approval refused: %s", exc)
            emit_metric("RemediationRefused", 1, Reason=str(exc.status))
            return _response(exc.status, {"error": str(exc)})

    def _handle(self, event: dict[str, Any]) -> dict[str, Any]:
        approver = caller_arn(event)
        if not any(approver.startswith(p) for p in self.config.approver_arn_prefixes):
            raise ApprovalError(403, f"{approver} is not an approved operator")

        body = parse_body(event)
        incident_id = str(body.get("incident_id", ""))
        decision = body.get("decision")
        justification = str(body.get("justification", ""))[:500]
        if decision not in {"approve", "reject"}:
            raise ApprovalError(400, "decision must be 'approve' or 'reject'")
        if len(justification) < 10:
            raise ApprovalError(400, "justification (>=10 chars) is required for the audit trail")

        incident = self.store.get(incident_id)
        if not incident:
            raise ApprovalError(404, f"incident {incident_id} not found")
        if incident.status not in ACTIONABLE:
            raise ApprovalError(409, f"incident is {incident.status}; nothing to approve")

        if decision == "reject":
            incident.status = IncidentStatus.REJECTED.value
            incident.add_history("REMEDIATION_REJECTED", approver, justification)
            self.store.put(incident)
            return {"incident_id": incident_id, "status": incident.status}

        recommended = incident.analysis.get("recommended_runbook", NONE)
        runbook_id = body.get("runbook_id") or recommended
        rb = CATALOG.get(runbook_id)
        if rb is None:
            raise ApprovalError(400, f"runbook {runbook_id!r} is not in the approved catalog")
        if Category(incident.category) not in rb.categories:
            raise ApprovalError(400, f"runbook {runbook_id} is not approved for {incident.category}")
        if not {"cluster", "service"} <= set(incident.resource):
            raise ApprovalError(422, "incident has no ECS resource to act on")

        params = rb.build_parameters(incident.resource, self.config.runbook_config)
        document = f"{self.config.name_prefix}-{rb.document_suffix}"
        incident.status = IncidentStatus.REMEDIATION_REQUESTED.value
        incident.add_history(
            "REMEDIATION_APPROVED",
            approver,
            f"{runbook_id} (risk {rb.risk}){' override of ' + recommended if runbook_id != recommended else ''}: {justification}",
        )
        self.store.put(incident)

        resp = self.ssm.start_automation_execution(
            DocumentName=document,
            Parameters=params,
            Tags=[{"Key": "IncidentId", "Value": incident_id}, {"Key": "ApprovedBy", "Value": approver[-250:]}],
        )
        execution_id = resp["AutomationExecutionId"]
        incident.status = IncidentStatus.REMEDIATING.value
        incident.remediation = {
            "runbook_id": runbook_id,
            "document": document,
            "risk": rb.risk,
            "execution_id": execution_id,
            "approved_by": approver,
            "second_approval_required": rb.risk == "HIGH",
        }
        incident.add_history("REMEDIATION_STARTED", "ssm", f"{document} execution {execution_id}")
        self.store.put(incident)
        self.store.set_execution_id(incident_id, execution_id)
        emit_metric("RemediationStarted", 1, Runbook=runbook_id, Risk=rb.risk)
        self.notifier.publish(
            f"Remediation started for {incident_id}",
            {
                "incident_id": incident_id,
                "runbook": runbook_id,
                "risk": rb.risk,
                "execution_id": execution_id,
                "approved_by": approver,
                "note": "HIGH risk: a second approver must approve the SSM execution" if rb.risk == "HIGH" else "",
            },
        )
        return {
            "incident_id": incident_id,
            "status": incident.status,
            "execution_id": execution_id,
            "runbook_id": runbook_id,
            "risk": rb.risk,
        }


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body)}


_service: RemediationService | None = None


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # pragma: no cover
    global _service
    if _service is None:
        cfg = Config.from_env()
        session = boto3.session.Session()
        _service = RemediationService(
            cfg,
            IncidentStore(session.resource("dynamodb").Table(cfg.table_name)),
            session.client("ssm"),
            Notifier(session.client("sns"), cfg.topic_arn),
        )
    return _service.handle(event)

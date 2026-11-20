import json

import pytest

from aiops.handlers.analyzer import AnalyzerService
from aiops.handlers.remediation import RemediationService
from aiops.handlers.status import StatusService
from aiops.store import IncidentStore
from conftest import load_fixture

OPERATOR = "arn:aws:sts::123456789012:assumed-role/aiops-dev-operator/alice"
INTRUDER = "arn:aws:sts::123456789012:assumed-role/some-other-role/mallory"


class FakeSSM:
    def __init__(self):
        self.calls = []

    def start_automation_execution(self, **kwargs):
        self.calls.append(kwargs)
        return {"AutomationExecutionId": "exec-123"}


def _request(body, arn=OPERATOR):
    ctx = {"authorizer": {"iam": {"userArn": arn}}} if arn else {}
    return {"requestContext": ctx, "body": json.dumps(body), "isBase64Encoded": False}


@pytest.fixture
def opened(config, table, fake_collector, fake_notifier, alarm_event):
    r = AnalyzerService(config, IncidentStore(table), fake_collector, fake_notifier).handle(alarm_event)
    return r["incident_id"]


@pytest.fixture
def svc(config, table, fake_notifier):
    return RemediationService(config, IncidentStore(table), FakeSSM(), fake_notifier)


def _call(svc, body, arn=OPERATOR):
    resp = svc.handle(_request(body, arn))
    return resp["statusCode"], json.loads(resp["body"])


GOOD_BODY = {"decision": "approve", "justification": "Tasks unhealthy, image unchanged - replace tasks."}


def test_approve_starts_only_the_approved_document(svc, opened, table):
    code, body = _call(svc, {**GOOD_BODY, "incident_id": opened})
    assert code == 200, body
    call = svc.ssm.calls[0]
    assert call["DocumentName"] == "aiops-dev-RestartEcsService"
    assert call["Parameters"]["ServiceName"] == ["aiops-dev-app"]
    inc = IncidentStore(table).get(opened)
    assert inc.status == "REMEDIATING"
    assert inc.remediation["approved_by"] == OPERATOR
    assert {"REMEDIATION_APPROVED", "REMEDIATION_STARTED"} <= {h["action"] for h in inc.history}


def test_unauthenticated_request_refused(svc, opened):
    code, _ = _call(svc, {**GOOD_BODY, "incident_id": opened}, arn=None)
    assert code == 401 and not svc.ssm.calls


def test_non_operator_refused(svc, opened):
    code, _ = _call(svc, {**GOOD_BODY, "incident_id": opened}, arn=INTRUDER)
    assert code == 403 and not svc.ssm.calls


def test_body_cannot_spoof_approver(svc, opened, table):
    _call(svc, {**GOOD_BODY, "incident_id": opened, "approver": "arn:aws:iam::1:root"})
    assert IncidentStore(table).get(opened).remediation["approved_by"] == OPERATOR


def test_justification_required(svc, opened):
    code, _ = _call(svc, {"decision": "approve", "incident_id": opened})
    assert code == 400 and not svc.ssm.calls


def test_runbook_outside_catalog_refused(svc, opened):
    code, body = _call(svc, {**GOOD_BODY, "incident_id": opened, "runbook_id": "AWS-RunShellScript"})
    assert code == 400 and "approved catalog" in body["error"] and not svc.ssm.calls


def test_runbook_not_approved_for_category_refused(svc, opened):
    code, _ = _call(svc, {**GOOD_BODY, "incident_id": opened, "runbook_id": "scale-out-ecs-service"})
    assert code == 400 and not svc.ssm.calls


def test_unknown_incident(svc):
    code, _ = _call(svc, {**GOOD_BODY, "incident_id": "INC-nope"})
    assert code == 404


def test_double_approval_conflict(svc, opened):
    assert _call(svc, {**GOOD_BODY, "incident_id": opened})[0] == 200
    assert _call(svc, {**GOOD_BODY, "incident_id": opened})[0] == 409
    assert len(svc.ssm.calls) == 1


def test_reject_records_decision(svc, opened, table):
    code, body = _call(
        svc, {"decision": "reject", "incident_id": opened, "justification": "Investigating DB first; no restart."}
    )
    assert code == 200 and body["status"] == "REJECTED"
    assert not svc.ssm.calls
    assert IncidentStore(table).get(opened).history[-1]["action"] == "REMEDIATION_REJECTED"


def test_high_risk_runbook_passes_second_approver(config, table, fake_collector, fake_notifier, alarm_event, svc):
    alarm_event["detail"]["alarmName"] = "aiops-dev-alb-5xx"
    alarm_event["detail"]["configuration"]["metrics"] = []
    inc_id = AnalyzerService(config, IncidentStore(table), fake_collector, fake_notifier).handle(alarm_event)[
        "incident_id"
    ]
    code, body = _call(svc, {**GOOD_BODY, "incident_id": inc_id})
    assert code == 200 and body["risk"] == "HIGH"
    assert svc.ssm.calls[0]["Parameters"]["Approvers"] == [config.high_risk_approver_arn]
    assert IncidentStore(table).get(inc_id).remediation["second_approval_required"] is True


def test_status_success_resolves(svc, opened, table, fake_notifier):
    _call(svc, {**GOOD_BODY, "incident_id": opened})
    r = StatusService(IncidentStore(table), fake_notifier).handle(load_fixture("ssm_execution_success.json"))
    assert r["status"] == "RESOLVED"
    inc = IncidentStore(table).get(opened)
    assert inc.history[-1]["action"] == "REMEDIATION_SUCCEEDED" and inc.resolved_at


def test_status_failure_marks_failed_and_allows_retry(svc, opened, table, fake_notifier):
    _call(svc, {**GOOD_BODY, "incident_id": opened})
    ev = load_fixture("ssm_execution_success.json")
    ev["detail"]["Status"] = "Failed"
    assert StatusService(IncidentStore(table), fake_notifier).handle(ev)["status"] == "REMEDIATION_FAILED"
    assert _call(svc, {**GOOD_BODY, "incident_id": opened})[0] == 200  # human may retry


def test_status_unknown_execution_ignored(table, fake_notifier):
    ev = load_fixture("ssm_execution_success.json")
    ev["detail"]["ExecutionId"] = "exec-unknown"
    assert StatusService(IncidentStore(table), fake_notifier).handle(ev)["action"] == "ignored"

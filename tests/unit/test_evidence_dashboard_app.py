import json
import threading
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

import pytest
import yaml

from aiops.events import normalise
from aiops.evidence import EvidenceCollector, redact
from aiops.handlers.dashboard import render
from aiops.models import Incident
from aiops.runbooks import CATALOG

ROOT = Path(__file__).resolve().parents[2]


class Stub:
    """Minimal boto3 client stub: attribute -> callable or canned response."""

    def __init__(self, **responses):
        self._r = responses

    def __getattr__(self, name):
        value = self._r[name]
        if isinstance(value, Exception):

            def boom(**_):
                raise value

            return boom
        return lambda **_: value


def _clients(**overrides):
    base = dict(
        cloudwatch=Stub(
            describe_alarm_history={"AlarmHistoryItems": [{"Timestamp": "t", "HistorySummary": "OK to ALARM"}]},
            get_metric_data={"MetricDataResults": [{"Id": "cpuutilization", "Values": [91.23, 88.0]}]},
        ),
        logs=Stub(filter_log_events={"events": [{"message": "ERROR db down password=hunter2"}]}),
        ecs=Stub(
            describe_services={
                "services": [
                    {
                        "status": "ACTIVE",
                        "desiredCount": 1,
                        "runningCount": 0,
                        "deployments": [],
                        "events": [{"message": "unhealthy"}],
                    }
                ]
            },
            list_tasks={"taskArns": ["arn:aws:ecs:...:task/c/t1"]},
            describe_tasks={
                "tasks": [
                    {
                        "taskArn": "arn/t1",
                        "stopCode": "TaskFailedToStart",
                        "stoppedReason": "x",
                        "containers": [{"name": "app", "exitCode": 1}],
                    }
                ]
            },
        ),
        elbv2=Stub(
            describe_target_health={
                "TargetHealthDescriptions": [
                    {"TargetHealth": {"State": "unhealthy", "Reason": "Target.ResponseCodeMismatch"}}
                ]
            }
        ),
    )
    base.update(overrides)
    return base


def test_collect_all_sources(alarm_event):
    signal = normalise(alarm_event, {"cluster": "c", "service": "s"})
    ev = EvidenceCollector(
        _clients(), {"target_group_arn": "tg", "app_log_group": "/g"}, now=lambda: datetime(2026, 11, 20, tzinfo=UTC)
    ).collect(signal)
    assert ev["target_health"] == {"total": 1, "healthy": 0, "unhealthy_reasons": ["Target.ResponseCodeMismatch"]}
    assert ev["ecs_service"]["running"] == 0
    assert ev["stopped_tasks"][0]["exit_codes"] == {"app": 1}
    assert ev["metrics"]["cpuutilization"] == [91.2, 88.0]
    assert "hunter2" not in json.dumps(ev)  # secrets redacted before storage / Bedrock


def test_collector_failure_is_recorded_not_raised(alarm_event):
    signal = normalise(alarm_event, {"cluster": "c", "service": "s"})
    clients = _clients(elbv2=Stub(describe_target_health=PermissionError("AccessDenied")))
    ev = EvidenceCollector(clients, {"target_group_arn": "tg", "app_log_group": "/g"}).collect(signal)
    assert "AccessDenied" in ev["target_health"]["error"]
    assert ev["ecs_service"]["status"] == "ACTIVE"


@pytest.mark.parametrize("raw", ["token=abc123", "Authorization: Bearer xyz", "key AKIAABCDEFGHIJKLMNOP"])
def test_redact(raw):
    out = redact(raw)
    assert "abc123" not in out and "xyz" not in out and "AKIAABCDEFGHIJKLMNOP" not in out


def _incident(**kw):
    base = dict(
        incident_id="INC-1",
        dedupe_key="k",
        title="t",
        category="UNHEALTHY_TARGETS",
        severity="SEV2",
        status="OPEN",
        created_at="2026-11-20T00:00:00+00:00",
        updated_at="x",
        resource={},
        signal={},
        evidence={},
        analysis={"probable_cause": "<script>alert(1)</script>", "recommended_runbook": "r"},
        history=[{"action": "DETECTED", "actor": "system"}],
    )
    base.update(kw)
    return Incident(**base)


def test_dashboard_render_escapes_html():
    out = render([_incident(), _incident(incident_id="INC-2", severity="SEV1", status="RESOLVED")])
    assert "<script>" not in out and "&lt;script&gt;" in out
    assert "INC-2" in out and "RESOLVED: 1" in out


def test_dashboard_empty():
    assert "No incidents" in render([])


# --- SSM documents ---------------------------------------------------------------
DOC_DIR = ROOT / "terraform" / "modules" / "remediation" / "documents"


@pytest.mark.parametrize("rb", list(CATALOG.values()), ids=lambda r: r.runbook_id)
def test_every_catalog_runbook_has_a_matching_ssm_document(rb, config):
    path = DOC_DIR / f"{rb.document_suffix}.yaml"
    assert path.exists(), f"missing {path}"
    doc = yaml.safe_load(path.read_text())
    assert doc["schemaVersion"] == "0.3"
    assert doc["assumeRole"] == "{{ AutomationAssumeRole }}"
    params = rb.build_parameters({"cluster": "c", "service": "s"}, config.runbook_config)
    assert set(params) <= set(doc["parameters"]), "runbook passes parameters the document does not declare"
    actions = [s["action"] for s in doc["mainSteps"]]
    if rb.risk == "HIGH":
        assert actions[0] == "aws:approve", "HIGH risk runbooks must start with a human approval step"
    # no arbitrary-code actions in approved runbooks
    assert "aws:runCommand" not in actions and "aws:executeScript" not in actions


# --- sample app ----------------------------------------------------------------------
@pytest.fixture
def app_url(monkeypatch):
    monkeypatch.setenv("FAULT_TOKEN", "t0k3n")
    import sys

    sys.path.insert(0, str(ROOT / "src" / "sample_app"))
    import app as sample

    sample.STATE.set(unhealthy=False, errors=False)
    srv = sample.make_server(0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def _get(url, method="GET", token=None):
    req = urllib.request.Request(url, method=method, headers={"X-Fault-Token": token} if token else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:  # nosec B310 - local test server
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def test_sample_app_fault_injection(app_url):
    assert _get(app_url + "/health") == 200
    assert _get(app_url + "/fault/unhealthy", "POST") == 403  # no token
    assert _get(app_url + "/fault/unhealthy", "POST", "wrong") == 403
    assert _get(app_url + "/fault/unhealthy", "POST", "t0k3n") == 200
    assert _get(app_url + "/health") == 503
    assert _get(app_url + "/fault/errors", "POST", "t0k3n") == 200
    assert _get(app_url + "/") == 500
    assert _get(app_url + "/fault/reset", "POST", "t0k3n") == 200
    assert _get(app_url + "/health") == 200 and _get(app_url + "/") == 200
    assert _get(app_url + "/work?ms=5") == 200

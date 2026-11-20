from test_ai import GOOD

from aiops.handlers.analyzer import AnalyzerService
from aiops.store import IncidentStore
from conftest import FakeAIClient, FakeCollector


def _svc(config, table, collector, notifier, ai=None):
    return AnalyzerService(config, IncidentStore(table), collector, notifier, ai)


def test_alarm_opens_incident(config, table, fake_collector, fake_notifier, alarm_event):
    svc = _svc(config, table, fake_collector, fake_notifier)
    result = svc.handle(alarm_event)
    assert result["action"] == "opened"
    assert result["severity"] == "SEV1"  # SEV2 escalated: 0 healthy targets in evidence
    inc = IncidentStore(table).get(result["incident_id"])
    assert inc.status == "OPEN"
    assert inc.analysis["recommended_runbook"] == "restart-ecs-service"
    assert [h["action"] for h in inc.history] == ["DETECTED", "ANALYSED", "REMEDIATION_RECOMMENDED"]
    assert fake_notifier.messages and "approve.py" in fake_notifier.messages[0][1]["approve_with"]


def test_repeat_alarm_is_deduplicated(config, table, fake_collector, fake_notifier, alarm_event):
    svc = _svc(config, table, fake_collector, fake_notifier)
    first = svc.handle(alarm_event)
    second = svc.handle(alarm_event)
    assert second == {"action": "deduplicated", "incident_id": first["incident_id"]}
    assert fake_collector.calls == 1  # no second investigation, no second Bedrock call


def test_ok_resolves_and_records_mttr(config, table, fake_collector, fake_notifier, alarm_event):
    svc = _svc(config, table, fake_collector, fake_notifier)
    opened = svc.handle(alarm_event)
    alarm_event["detail"]["state"]["value"] = "OK"
    resolved = svc.handle(alarm_event)
    assert resolved["action"] == "resolved"
    inc = IncidentStore(table).get(opened["incident_id"])
    assert inc.status == "RESOLVED" and inc.resolved_at
    assert inc.history[-1]["action"] == "RECOVERED"


def test_ok_without_incident_is_ignored(config, table, fake_collector, fake_notifier, alarm_event):
    alarm_event["detail"]["state"]["value"] = "OK"
    assert _svc(config, table, fake_collector, fake_notifier).handle(alarm_event)["action"] == "ignored"


def test_task_stop_correlates_with_open_service_incident(
    config, table, fake_collector, fake_notifier, alarm_event, ecs_event
):
    svc = _svc(config, table, fake_collector, fake_notifier)
    opened = svc.handle(alarm_event)
    r = svc.handle(ecs_event)
    assert r == {"action": "deduplicated", "incident_id": opened["incident_id"]}


def test_standalone_task_stop_opens_incident(config, table, fake_notifier, ecs_event):
    r = _svc(config, table, FakeCollector({}), fake_notifier).handle(ecs_event)
    assert r["action"] == "opened" and r["severity"] == "SEV3"


def test_expected_task_stop_ignored(config, table, fake_collector, fake_notifier, ecs_event):
    ecs_event["detail"]["stopCode"] = "ServiceSchedulerInitiated"
    ecs_event["detail"]["stoppedReason"] = "Scaling activity initiated by (deployment ecs-svc/123)"
    assert _svc(config, table, fake_collector, fake_notifier).handle(ecs_event)["action"] == "ignored"


def test_unsupported_event_ignored(config, table, fake_collector, fake_notifier):
    r = _svc(config, table, fake_collector, fake_notifier).handle({"source": "x", "detail-type": "y"})
    assert r["action"] == "ignored"


def test_bedrock_used_when_enabled_and_quota_enforced(config, table, fake_collector, fake_notifier, alarm_event):
    config.bedrock_enabled = True
    config.bedrock_daily_limit = 1
    ai = FakeAIClient(payload=GOOD)
    svc = _svc(config, table, fake_collector, fake_notifier, ai)
    r1 = svc.handle(alarm_event)
    assert r1["engine"].startswith("bedrock:")
    # different incident (other category) on the same day: quota exhausted -> rules
    alarm_event["detail"]["alarmName"] = "aiops-dev-cpu-high"
    alarm_event["detail"]["configuration"]["metrics"] = []
    r2 = svc.handle(alarm_event)
    assert r2["action"] == "opened" and r2["engine"] == "rules"
    assert len(ai.messages.requests) == 1


def test_analyzer_never_starts_remediation(config, table, fake_collector, fake_notifier, alarm_event):
    """The analyzer has no SSM client at all - recommendation only."""
    svc = _svc(config, table, fake_collector, fake_notifier, FakeAIClient(payload=GOOD))
    assert not any("ssm" in k.lower() for k in vars(svc))
    inc_id = svc.handle(alarm_event)["incident_id"]
    assert IncidentStore(table).get(inc_id).status == "OPEN"

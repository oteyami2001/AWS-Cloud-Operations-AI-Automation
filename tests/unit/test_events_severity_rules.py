import pytest

from aiops import rules
from aiops.events import UnsupportedEvent, normalise
from aiops.models import Category, Severity
from aiops.runbooks import CATALOG, NONE
from aiops.severity import classify

DEFAULT = {"cluster": "aiops-dev-cluster", "service": "aiops-dev-app"}


def test_alarm_event_normalised(alarm_event):
    s = normalise(alarm_event, DEFAULT)
    assert s.source == "cloudwatch-alarm"
    assert s.state == "ALARM"
    assert s.category is Category.UNHEALTHY_TARGETS
    assert s.resource["service"] == "aiops-dev-app"
    assert s.resource["target_group"].startswith("targetgroup/")
    assert s.dedupe_key == "UNHEALTHY_TARGETS#aiops-dev-app"


@pytest.mark.parametrize(
    "suffix,category",
    [
        ("no-healthy-targets", Category.NO_HEALTHY_TARGETS),
        ("alb-5xx", Category.APPLICATION_ERRORS),
        ("app-errors", Category.APPLICATION_ERRORS),
        ("cpu-high", Category.HIGH_CPU),
        ("memory-high", Category.HIGH_MEMORY),
    ],
)
def test_alarm_category_from_name(alarm_event, suffix, category):
    alarm_event["detail"]["alarmName"] = f"aiops-dev-{suffix}"
    alarm_event["detail"]["configuration"]["metrics"] = []
    assert normalise(alarm_event, DEFAULT).category is category


def test_unknown_alarm_falls_back_to_metric_then_unknown(alarm_event):
    alarm_event["detail"]["alarmName"] = "something-else"
    assert normalise(alarm_event, DEFAULT).category is Category.UNHEALTHY_TARGETS  # from metric name
    alarm_event["detail"]["configuration"]["metrics"] = []
    assert normalise(alarm_event, DEFAULT).category is Category.UNKNOWN


def test_ecs_event_normalised(ecs_event):
    s = normalise(ecs_event, {})
    assert s.category is Category.TASK_STOPPED
    assert s.resource == {"cluster": "aiops-dev-cluster", "service": "aiops-dev-app"}
    assert "137" in s.reason


def test_unsupported_event():
    with pytest.raises(UnsupportedEvent):
        normalise({"source": "aws.s3", "detail-type": "Object Created"})


def test_severity_base_and_escalation(alarm_event):
    s = normalise(alarm_event, DEFAULT)
    assert classify(s, {}) is Severity.SEV2
    # zero healthy targets escalates one level
    assert classify(s, {"target_health": {"total": 2, "healthy": 0}}) is Severity.SEV1
    assert classify(s, {"target_health": {"total": 2, "healthy": 1}}) is Severity.SEV2


def test_rules_cover_every_category_with_catalog_runbooks(alarm_event):
    s = normalise(alarm_event, DEFAULT)
    for category in Category:
        s.category = category
        a = rules.analyse(s, {})
        assert a.engine == "rules"
        assert a.recommended_runbook == NONE or a.recommended_runbook in CATALOG
        if a.recommended_runbook != NONE:
            # rule recommendation must be approved for that category
            assert category in CATALOG[a.recommended_runbook].categories


def test_rules_use_evidence(alarm_event):
    s = normalise(alarm_event, DEFAULT)
    s.category = Category.NO_HEALTHY_TARGETS
    a = rules.analyse(s, {"ecs_service": {"desired": 0}, "target_health": {"total": 0}})
    assert "desired count is 0" in a.probable_cause
    assert a.confidence == "medium"
    assert a.recommended_runbook == "restore-ecs-desired-count"


def test_rules_detect_oom(ecs_event):
    s = normalise(ecs_event, {})
    a = rules.analyse(s, {"stopped_tasks": [{"exit_codes": {"app": 137}}]})
    assert "137" in a.probable_cause


def test_catalog_parameters_come_from_trusted_resource(config):
    resource = {"cluster": "c1", "service": "s1"}
    for rb in CATALOG.values():
        params = rb.build_parameters(resource, config.runbook_config)
        assert params["ClusterName"] == ["c1"]
        assert params["ServiceName"] == ["s1"]
        assert params["AutomationAssumeRole"] == [config.automation_role_arn]
        if rb.risk == "HIGH":
            assert params["Approvers"] == [config.high_risk_approver_arn]

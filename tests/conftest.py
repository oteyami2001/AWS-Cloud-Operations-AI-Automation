import copy
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import boto3
import pytest
from moto import mock_aws

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")

from aiops.platform import Config  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures"


def load_fixture(name: str) -> dict:
    return copy.deepcopy(json.loads((FIXTURES / name).read_text()))


@pytest.fixture
def alarm_event():
    return load_fixture("alarm_unhealthy.json")


@pytest.fixture
def ecs_event():
    return load_fixture("ecs_task_stopped.json")


@pytest.fixture
def config():
    return Config(
        table_name="aiops-test-incidents",
        topic_arn="",
        region="us-east-1",
        name_prefix="aiops-dev",
        cluster="aiops-dev-cluster",
        service="aiops-dev-app",
        target_group_arn="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/aiops-dev-tg/0123",
        app_log_group="/aiops/dev/app",
        automation_role_arn="arn:aws:iam::123456789012:role/aiops-dev-automation",
        high_risk_approver_arn="arn:aws:iam::123456789012:role/aiops-dev-senior-approver",
        baseline_desired_count="1",
        max_desired_count="2",
        bedrock_enabled=False,
        bedrock_model_id="anthropic.claude-opus-5-5",
        bedrock_effort="medium",
        bedrock_daily_limit=5,
        approver_arn_prefixes=["arn:aws:sts::123456789012:assumed-role/aiops-dev-operator/"],
    )


@pytest.fixture
def table(config):
    """DynamoDB table with the same keys/GSIs as terraform/modules/aiops/dynamodb.tf."""
    with mock_aws():
        ddb = boto3.resource("dynamodb", region_name="us-east-1")
        t = ddb.create_table(
            TableName=config.table_name,
            BillingMode="PAY_PER_REQUEST",
            KeySchema=[{"AttributeName": "incident_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "incident_id", "AttributeType": "S"},
                {"AttributeName": "dedupe_key", "AttributeType": "S"},
                {"AttributeName": "created_at", "AttributeType": "S"},
                {"AttributeName": "execution_id", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "by_dedupe_key",
                    "KeySchema": [
                        {"AttributeName": "dedupe_key", "KeyType": "HASH"},
                        {"AttributeName": "created_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                },
                {
                    "IndexName": "by_execution_id",
                    "KeySchema": [{"AttributeName": "execution_id", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "ALL"},
                },
            ],
        )
        yield t


class FakeCollector:
    def __init__(self, evidence=None):
        self.evidence = (
            evidence
            if evidence is not None
            else {
                "ecs_service": {"desired": 1, "running": 1},
                "target_health": {"total": 1, "healthy": 0, "unhealthy_reasons": ["Target.ResponseCodeMismatch"]},
                "recent_errors": ["health check failing: dependency 'orders-db' unreachable"],
            }
        )
        self.calls = 0

    def collect(self, signal):
        self.calls += 1
        return copy.deepcopy(self.evidence)


class FakeNotifier:
    def __init__(self):
        self.messages = []

    def publish(self, subject, body):
        self.messages.append((subject, body))


class FakeMessages:
    def __init__(self, payload=None, stop_reason="end_turn", exc=None):
        self.payload = payload
        self.stop_reason = stop_reason
        self.exc = exc
        self.requests = []

    def create(self, **kwargs):
        self.requests.append(kwargs)
        if self.exc:
            raise self.exc
        text = self.payload if isinstance(self.payload, str) else json.dumps(self.payload)
        return SimpleNamespace(stop_reason=self.stop_reason, content=[SimpleNamespace(type="text", text=text)])


class FakeAIClient:
    def __init__(self, **kwargs):
        self.messages = FakeMessages(**kwargs)


@pytest.fixture
def fake_collector():
    return FakeCollector()


@pytest.fixture
def fake_notifier():
    return FakeNotifier()

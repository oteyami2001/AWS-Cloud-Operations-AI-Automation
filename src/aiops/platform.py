"""Runtime wiring: configuration from environment variables, AWS clients, metrics, notifications."""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger(__name__)


@dataclass
class Config:
    table_name: str
    topic_arn: str
    region: str
    name_prefix: str
    cluster: str
    service: str
    target_group_arn: str
    app_log_group: str
    automation_role_arn: str
    high_risk_approver_arn: str
    baseline_desired_count: str
    max_desired_count: str
    bedrock_enabled: bool
    bedrock_model_id: str
    bedrock_effort: str
    bedrock_daily_limit: int
    approver_arn_prefixes: list[str] = field(default_factory=list)
    dashboard_url: str = ""

    @classmethod
    def from_env(cls) -> Config:
        env = os.environ
        return cls(
            table_name=env.get("INCIDENT_TABLE", "aiops-incidents"),
            topic_arn=env.get("NOTIFY_TOPIC_ARN", ""),
            region=env.get("AWS_REGION", "us-east-2"),
            name_prefix=env.get("NAME_PREFIX", "aiops-dev"),
            cluster=env.get("ECS_CLUSTER", ""),
            service=env.get("ECS_SERVICE", ""),
            target_group_arn=env.get("TARGET_GROUP_ARN", ""),
            app_log_group=env.get("APP_LOG_GROUP", ""),
            automation_role_arn=env.get("AUTOMATION_ROLE_ARN", ""),
            high_risk_approver_arn=env.get("HIGH_RISK_APPROVER_ARN", ""),
            baseline_desired_count=env.get("BASELINE_DESIRED_COUNT", "1"),
            max_desired_count=env.get("MAX_DESIRED_COUNT", "2"),
            bedrock_enabled=env.get("BEDROCK_ENABLED", "false").lower() == "true",
            bedrock_model_id=env.get("BEDROCK_MODEL_ID", "anthropic.claude-opus-5-5"),
            bedrock_effort=env.get("BEDROCK_EFFORT", "medium"),
            bedrock_daily_limit=int(env.get("BEDROCK_DAILY_CALL_LIMIT", "20")),
            approver_arn_prefixes=[p for p in env.get("APPROVER_ARN_PREFIXES", "").split(",") if p],
            dashboard_url=env.get("DASHBOARD_URL", ""),
        )

    @property
    def default_resource(self) -> dict[str, str]:
        return {k: v for k, v in {"cluster": self.cluster, "service": self.service}.items() if v}

    @property
    def runbook_config(self) -> dict[str, str]:
        return {
            "automation_role_arn": self.automation_role_arn,
            "high_risk_approver_arn": self.high_risk_approver_arn,
            "baseline_desired_count": self.baseline_desired_count,
            "max_desired_count": self.max_desired_count,
        }


def emit_metric(name: str, value: float, unit: str = "Count", **dimensions: str) -> None:
    """CloudWatch Embedded Metric Format - written to stdout, no PutMetricData permission needed."""
    if os.environ.get("AIOPS_DISABLE_EMF") == "1":  # local demos / transcripts
        return
    payload: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {"Namespace": "AIOps", "Dimensions": [sorted(dimensions)], "Metrics": [{"Name": name, "Unit": unit}]}
            ],
        },
        name: value,
        **dimensions,
    }
    print(json.dumps(payload))  # noqa: T201 - EMF requires stdout


class Notifier:
    def __init__(self, sns_client: Any, topic_arn: str):
        self.sns = sns_client
        self.topic_arn = topic_arn

    def publish(self, subject: str, body: dict[str, Any]) -> None:
        if not self.topic_arn:
            return
        try:
            self.sns.publish(
                TopicArn=self.topic_arn, Subject=subject[:100], Message=json.dumps(body, indent=2, default=str)
            )
        except Exception as exc:  # noqa: BLE001 - notification failure must not lose the incident
            log.error("SNS publish failed: %s", exc)

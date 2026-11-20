"""Evidence collection. Every collector is read-only and failure-tolerant: a failed collector
records its error instead of aborting the investigation."""

from __future__ import annotations

import logging
import re
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any

from .models import Signal

log = logging.getLogger(__name__)

MAX_LOG_LINES = 25
MAX_LINE_CHARS = 400
_SECRET_PATTERNS = [
    re.compile(r"(?i)\bbearer\s+\S+"),
    re.compile(r"(?i)(authorization|token|secret|password|api[_-]?key)(\"?\s*[:=]\s*)\S+"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
]


def redact(text: str) -> str:
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub(lambda m: (m.group(1) + m.group(2) + "[REDACTED]") if m.lastindex else "[REDACTED]", text)
    return text[:MAX_LINE_CHARS]


class EvidenceCollector:
    def __init__(self, clients: dict[str, Any], config: dict[str, str], now: Callable[[], datetime] | None = None):
        self.cw = clients.get("cloudwatch")
        self.logs = clients.get("logs")
        self.ecs = clients.get("ecs")
        self.elbv2 = clients.get("elbv2")
        self.config = config
        self.now = now or (lambda: datetime.now(UTC))

    # --- individual collectors -------------------------------------------------
    def alarm_history(self, signal: Signal) -> list[dict[str, str]]:
        if signal.source != "cloudwatch-alarm":
            return []
        resp = self.cw.describe_alarm_history(
            AlarmName=signal.name, HistoryItemType="StateUpdate", MaxRecords=5, ScanBy="TimestampDescending"
        )
        return [{"at": str(i["Timestamp"]), "summary": i["HistorySummary"]} for i in resp.get("AlarmHistoryItems", [])]

    def ecs_service(self, signal: Signal) -> dict[str, Any]:
        cluster, service = signal.resource.get("cluster"), signal.resource.get("service")
        if not (cluster and service):
            return {}
        resp = self.ecs.describe_services(cluster=cluster, services=[service])
        if not resp.get("services"):
            return {"error": "service not found"}
        svc = resp["services"][0]
        return {
            "status": svc.get("status"),
            "desired": svc.get("desiredCount"),
            "running": svc.get("runningCount"),
            "pending": svc.get("pendingCount"),
            "task_definition": svc.get("taskDefinition"),
            "deployments": [
                {
                    "status": d.get("status"),
                    "rollout": d.get("rolloutState"),
                    "task_definition": d.get("taskDefinition"),
                    "running": d.get("runningCount"),
                    "failed_tasks": d.get("failedTasks"),
                    "updated": str(d.get("updatedAt")),
                }
                for d in svc.get("deployments", [])[:3]
            ],
            "recent_events": [redact(e.get("message", "")) for e in svc.get("events", [])[:8]],
        }

    def stopped_tasks(self, signal: Signal) -> list[dict[str, Any]]:
        cluster, service = signal.resource.get("cluster"), signal.resource.get("service")
        if not (cluster and service):
            return []
        arns = self.ecs.list_tasks(cluster=cluster, serviceName=service, desiredStatus="STOPPED", maxResults=5).get(
            "taskArns", []
        )
        if not arns:
            return []
        tasks = self.ecs.describe_tasks(cluster=cluster, tasks=arns).get("tasks", [])
        return [
            {
                "task": t.get("taskArn", "").rsplit("/", 1)[-1],
                "stop_code": t.get("stopCode"),
                "stopped_reason": redact(t.get("stoppedReason", "")),
                "exit_codes": {c.get("name"): c.get("exitCode") for c in t.get("containers", [])},
            }
            for t in tasks
        ]

    def target_health(self, signal: Signal) -> dict[str, Any]:
        tg_arn = self.config.get("target_group_arn")
        if not tg_arn:
            return {}
        descs = self.elbv2.describe_target_health(TargetGroupArn=tg_arn).get("TargetHealthDescriptions", [])
        states = [d.get("TargetHealth", {}) for d in descs]
        return {
            "total": len(states),
            "healthy": sum(1 for s in states if s.get("State") == "healthy"),
            "unhealthy_reasons": sorted({s.get("Reason", "") for s in states if s.get("State") != "healthy"} - {""}),
        }

    def recent_errors(self, signal: Signal) -> list[str]:
        group = self.config.get("app_log_group")
        if not group:
            return []
        start = int((self.now() - timedelta(minutes=15)).timestamp() * 1000)
        resp = self.logs.filter_log_events(
            logGroupName=group, startTime=start, filterPattern="?ERROR ?Exception ?Traceback", limit=MAX_LOG_LINES
        )
        return [redact(e.get("message", "").strip()) for e in resp.get("events", [])]

    def metrics(self, signal: Signal) -> dict[str, list[float]]:
        cluster, service = signal.resource.get("cluster"), signal.resource.get("service")
        if not (cluster and service):
            return {}
        end = self.now()
        queries = [
            {
                "Id": metric.lower(),
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/ECS",
                        "MetricName": metric,
                        "Dimensions": [
                            {"Name": "ClusterName", "Value": cluster},
                            {"Name": "ServiceName", "Value": service},
                        ],
                    },
                    "Period": 60,
                    "Stat": "Average",
                },
            }
            for metric in ("CPUUtilization", "MemoryUtilization")
        ]
        resp = self.cw.get_metric_data(MetricDataQueries=queries, StartTime=end - timedelta(minutes=15), EndTime=end)
        return {r["Id"]: [round(v, 1) for v in r.get("Values", [])[:15]] for r in resp.get("MetricDataResults", [])}

    # --- orchestration ---------------------------------------------------------
    def collect(self, signal: Signal) -> dict[str, Any]:
        evidence: dict[str, Any] = {
            "signal": {
                "source": signal.source,
                "name": signal.name,
                "state": signal.state,
                "reason": redact(signal.reason),
                "timestamp": signal.timestamp,
            }
        }
        collectors = {
            "alarm_history": self.alarm_history,
            "ecs_service": self.ecs_service,
            "stopped_tasks": self.stopped_tasks,
            "target_health": self.target_health,
            "recent_errors": self.recent_errors,
            "metrics": self.metrics,
        }
        for key, fn in collectors.items():
            try:
                evidence[key] = fn(signal)
            except Exception as exc:  # noqa: BLE001 - evidence gathering must never abort analysis
                log.warning("collector %s failed: %s", key, exc)
                evidence[key] = {"error": f"{type(exc).__name__}: {exc}"[:300]}
        return evidence

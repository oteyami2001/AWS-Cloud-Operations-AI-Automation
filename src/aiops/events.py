"""Normalise EventBridge events into :class:`Signal` objects.

Supported event types:
* ``CloudWatch Alarm State Change`` (source ``aws.cloudwatch``)
* ``ECS Task State Change`` (source ``aws.ecs``) for tasks that stopped unexpectedly
"""

from __future__ import annotations

from typing import Any

from .models import Category, Signal

# Alarm names created by terraform/modules/monitoring follow "<prefix>-<kind>".
_ALARM_KIND_TO_CATEGORY = {
    "unhealthy-targets": Category.UNHEALTHY_TARGETS,
    "no-healthy-targets": Category.NO_HEALTHY_TARGETS,
    "alb-5xx": Category.APPLICATION_ERRORS,
    "app-errors": Category.APPLICATION_ERRORS,
    "cpu-high": Category.HIGH_CPU,
    "memory-high": Category.HIGH_MEMORY,
}

_ALARM_METRIC_TO_CATEGORY = {
    "UnHealthyHostCount": Category.UNHEALTHY_TARGETS,
    "HealthyHostCount": Category.NO_HEALTHY_TARGETS,
    "HTTPCode_Target_5XX_Count": Category.APPLICATION_ERRORS,
    "CPUUtilization": Category.HIGH_CPU,
    "MemoryUtilization": Category.HIGH_MEMORY,
}


class UnsupportedEvent(ValueError):
    pass


def _alarm_category(alarm_name: str, metric_name: str | None) -> Category:
    for kind, category in _ALARM_KIND_TO_CATEGORY.items():
        if alarm_name.endswith(kind):
            return category
    if metric_name and metric_name in _ALARM_METRIC_TO_CATEGORY:
        return _ALARM_METRIC_TO_CATEGORY[metric_name]
    return Category.UNKNOWN


def _alarm_resource(detail: dict[str, Any]) -> tuple[dict[str, str], str | None]:
    resource: dict[str, str] = {}
    metric_name = None
    for metric in detail.get("configuration", {}).get("metrics", []):
        stat = metric.get("metricStat", {}).get("metric", {})
        if not stat:
            continue
        metric_name = metric_name or stat.get("name")
        dims = stat.get("dimensions", {})
        mapping = {
            "ClusterName": "cluster",
            "ServiceName": "service",
            "TargetGroup": "target_group",
            "LoadBalancer": "load_balancer",
        }
        for dim, key in mapping.items():
            if dim in dims:
                resource[key] = dims[dim]
    return resource, metric_name


def from_alarm_event(event: dict[str, Any], default_resource: dict[str, str]) -> Signal:
    detail = event["detail"]
    name = detail["alarmName"]
    resource, metric_name = _alarm_resource(detail)
    # Alarms on ALB metrics don't carry ECS dimensions - fill from deployment config.
    merged = {**default_resource, **resource}
    state = detail.get("state", {})
    return Signal(
        source="cloudwatch-alarm",
        name=name,
        state=state.get("value", "UNKNOWN"),
        category=_alarm_category(name, metric_name),
        reason=state.get("reason", ""),
        region=event.get("region", ""),
        account=event.get("account", ""),
        timestamp=state.get("timestamp") or event.get("time", ""),
        resource=merged,
        raw={"alarm_arn": (event.get("resources") or [""])[0], "metric": metric_name or ""},
    )


def from_ecs_task_event(event: dict[str, Any], default_resource: dict[str, str]) -> Signal:
    detail = event["detail"]
    group = detail.get("group", "")  # "service:<name>"
    service = group.split(":", 1)[1] if group.startswith("service:") else default_resource.get("service", "")
    cluster = detail.get("clusterArn", "").rsplit("/", 1)[-1] or default_resource.get("cluster", "")
    containers = detail.get("containers", [])
    exit_codes = {c.get("name"): c.get("exitCode") for c in containers}
    reason = detail.get("stoppedReason", "") or detail.get("stopCode", "")
    return Signal(
        source="ecs-task",
        name=detail.get("taskArn", "unknown-task"),
        state=detail.get("lastStatus", "UNKNOWN"),
        category=Category.TASK_STOPPED,
        reason=f"{reason} exitCodes={exit_codes}",
        region=event.get("region", ""),
        account=event.get("account", ""),
        timestamp=detail.get("stoppedAt") or event.get("time", ""),
        resource={**default_resource, "cluster": cluster, "service": service},
        raw={"stop_code": detail.get("stopCode", ""), "task_definition": detail.get("taskDefinitionArn", "")},
    )


def normalise(event: dict[str, Any], default_resource: dict[str, str] | None = None) -> Signal:
    default_resource = default_resource or {}
    detail_type = event.get("detail-type")
    if detail_type == "CloudWatch Alarm State Change":
        return from_alarm_event(event, default_resource)
    if detail_type == "ECS Task State Change":
        return from_ecs_task_event(event, default_resource)
    raise UnsupportedEvent(f"Unsupported event: source={event.get('source')} detail-type={detail_type}")

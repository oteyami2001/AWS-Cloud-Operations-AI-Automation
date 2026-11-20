"""Deterministic rule-based analysis.

Used when Bedrock is disabled, over its daily quota, errors, refuses, or returns an invalid
answer. It guarantees every incident still gets a usable summary and recommendation.
"""

from __future__ import annotations

from typing import Any

from .models import Analysis, Category, Signal
from .runbooks import NONE

_PLAYBOOK: dict[Category, dict[str, Any]] = {
    Category.NO_HEALTHY_TARGETS: {
        "cause": "The ECS service has no healthy tasks registered behind the load balancer. "
        "Most commonly the service was scaled to zero or every task is crash-looping.",
        "steps": [
            "Check ECS service desired/running counts.",
            "Review the last ECS service events for placement or deployment failures.",
            "Inspect stopped task reasons and container exit codes.",
        ],
        "runbook": "restore-ecs-desired-count",
    },
    Category.UNHEALTHY_TARGETS: {
        "cause": "One or more targets are failing the ALB health check (/health). The application "
        "process is running but reporting unhealthy, or is not responding in time.",
        "steps": [
            "Check target health reasons in the target group.",
            "Search application logs for errors around the alarm time.",
            "If tasks are unhealthy but the image has not changed, replace them with a fresh deployment.",
        ],
        "runbook": "restart-ecs-service",
    },
    Category.APPLICATION_ERRORS: {
        "cause": "The application is returning elevated HTTP 5xx responses / logging errors.",
        "steps": [
            "Correlate the error spike with the most recent deployment.",
            "Review the top error messages in the application log group.",
            "If a recent deployment introduced the errors, roll back to the previous task definition.",
        ],
        "runbook": "rollback-ecs-task-definition",
    },
    Category.HIGH_CPU: {
        "cause": "Sustained CPU utilisation above threshold - load increase or a hot code path.",
        "steps": [
            "Check request count trend on the ALB.",
            "Check for a recent deployment.",
            "Scale out if load-driven.",
        ],
        "runbook": "scale-out-ecs-service",
    },
    Category.HIGH_MEMORY: {
        "cause": "Sustained memory utilisation above threshold - load increase or a memory leak.",
        "steps": ["Check memory trend since last deployment.", "Look for OOM-killed tasks (exit code 137)."],
        "runbook": "restart-ecs-service",
    },
    Category.TASK_STOPPED: {
        "cause": "An ECS task stopped unexpectedly.",
        "steps": ["Inspect the stop code and container exit codes.", "Review application logs before the stop."],
        "runbook": "restart-ecs-service",
    },
}


def analyse(signal: Signal, evidence: dict[str, Any]) -> Analysis:
    entry = _PLAYBOOK.get(signal.category)
    if not entry:
        return Analysis(
            summary=f"Unclassified signal {signal.name} entered {signal.state}.",
            probable_cause="Unknown - manual investigation required.",
            confidence="low",
            troubleshooting_steps=["Review the alarm definition and recent changes."],
            recommended_runbook=NONE,
            rationale="No rule matches this signal category.",
            engine="rules",
        )

    cause = entry["cause"]
    refs: list[str] = []
    svc = evidence.get("ecs_service") or {}
    if isinstance(svc, dict) and svc.get("desired") == 0:
        cause = "The ECS service desired count is 0, so no tasks are running (service stopped or scaled in)."
        refs.append("ecs_service.desired=0")
    stopped = evidence.get("stopped_tasks") or []
    if isinstance(stopped, list):
        exit_137 = [t for t in stopped if 137 in (t.get("exit_codes") or {}).values()]
        if exit_137:
            cause += " Stopped tasks exited with code 137 (OOM kill / SIGKILL)."
            refs.append("stopped_tasks.exit_code=137")
    th = evidence.get("target_health") or {}
    if isinstance(th, dict) and th.get("total"):
        refs.append(f"target_health.healthy={th.get('healthy')}/{th.get('total')}")

    return Analysis(
        summary=f"{signal.category.value.replace('_', ' ').title()} detected: {signal.name} is {signal.state}.",
        probable_cause=cause,
        confidence="medium" if refs else "low",
        troubleshooting_steps=list(entry["steps"]),
        recommended_runbook=entry["runbook"],
        rationale="Deterministic playbook match on signal category.",
        engine="rules",
        evidence_refs=refs,
    )

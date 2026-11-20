"""Catalog of APPROVED remediation runbooks.

This is the single allowlist of actions the platform can ever execute. The AI model may only
*choose an id* from this catalog; it never supplies document names or parameters. Parameters
are built here from the incident's resource identifiers, which come from trusted AWS event data
and the deployment configuration - never from model output.

Every runbook requires a human to request it (see handlers/remediation.py). Runbooks marked
``HIGH`` additionally contain an ``aws:approve`` step inside the SSM document, so a second
approval is enforced natively by Systems Manager before any change is made.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from .models import Category


@dataclass(frozen=True)
class Runbook:
    runbook_id: str
    document_suffix: str  # SSM document name = f"{prefix}-{suffix}"
    risk: str  # LOW | MEDIUM | HIGH
    description: str
    categories: tuple[Category, ...]
    build_parameters: Callable[[dict[str, str], dict[str, str]], dict[str, list[str]]]


def _svc_params(resource: dict[str, str], cfg: dict[str, str]) -> dict[str, list[str]]:
    return {
        "ClusterName": [resource["cluster"]],
        "ServiceName": [resource["service"]],
        "AutomationAssumeRole": [cfg["automation_role_arn"]],
    }


def _restore_params(resource: dict[str, str], cfg: dict[str, str]) -> dict[str, list[str]]:
    return {**_svc_params(resource, cfg), "DesiredCount": [cfg.get("baseline_desired_count", "1")]}


def _scale_out_params(resource: dict[str, str], cfg: dict[str, str]) -> dict[str, list[str]]:
    return {**_svc_params(resource, cfg), "DesiredCount": [cfg.get("max_desired_count", "2")]}


def _rollback_params(resource: dict[str, str], cfg: dict[str, str]) -> dict[str, list[str]]:
    return {**_svc_params(resource, cfg), "Approvers": [cfg["high_risk_approver_arn"]]}


CATALOG: dict[str, Runbook] = {
    rb.runbook_id: rb
    for rb in (
        Runbook(
            "restart-ecs-service",
            "RestartEcsService",
            "MEDIUM",
            "Force a new deployment of the ECS service so unhealthy tasks are replaced.",
            (Category.UNHEALTHY_TARGETS, Category.TASK_STOPPED, Category.HIGH_MEMORY),
            _svc_params,
        ),
        Runbook(
            "restore-ecs-desired-count",
            "RestoreEcsDesiredCount",
            "MEDIUM",
            "Set the ECS service desired count back to its approved baseline.",
            (Category.NO_HEALTHY_TARGETS,),
            _restore_params,
        ),
        Runbook(
            "scale-out-ecs-service",
            "ScaleOutEcsService",
            "MEDIUM",
            "Raise the ECS service desired count to the approved maximum (bounded).",
            (Category.HIGH_CPU, Category.HIGH_MEMORY),
            _scale_out_params,
        ),
        Runbook(
            "rollback-ecs-task-definition",
            "RollbackEcsTaskDefinition",
            "HIGH",
            "Roll the ECS service back to the previous task definition revision. "
            "Pauses for a second human approval inside SSM (aws:approve).",
            (Category.APPLICATION_ERRORS, Category.TASK_STOPPED),
            _rollback_params,
        ),
    )
}

NONE = "NONE"


def allowed_ids() -> list[str]:
    return sorted(CATALOG) + [NONE]


def candidates_for(category: Category) -> list[Runbook]:
    return [rb for rb in CATALOG.values() if category in rb.categories]


def describe_for_prompt(category: Category) -> list[dict[str, str]]:
    return [{"id": rb.runbook_id, "risk": rb.risk, "description": rb.description} for rb in candidates_for(category)]

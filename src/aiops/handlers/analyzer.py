"""Incident Analyzer Lambda.

Triggered by EventBridge for CloudWatch alarm state changes and ECS task state changes.

ALARM / STOPPED -> dedupe -> collect evidence -> severity -> AI/rules analysis -> store -> notify
OK              -> resolve the matching open incident and record the recovery

This function has NO permission to run SSM Automation or modify ECS (see terraform/modules/aiops/iam.tf).
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import Any

import boto3

from ..ai import BedrockAnalyzer, build_client
from ..events import UnsupportedEvent, normalise
from ..evidence import EvidenceCollector
from ..models import Incident, IncidentStatus, Signal, utcnow
from ..platform import Config, Notifier, emit_metric
from ..runbooks import CATALOG
from ..severity import classify
from ..store import IncidentStore

log = logging.getLogger()
log.setLevel(logging.INFO)


class AnalyzerService:
    def __init__(
        self,
        config: Config,
        store: IncidentStore,
        collector: EvidenceCollector,
        notifier: Notifier,
        ai_client: Any = None,
    ):
        self.config = config
        self.store = store
        self.collector = collector
        self.notifier = notifier
        self.ai_client = ai_client

    def handle(self, event: dict[str, Any]) -> dict[str, Any]:
        try:
            signal = normalise(event, self.config.default_resource)
        except UnsupportedEvent as exc:
            log.info("ignored: %s", exc)
            return {"action": "ignored", "reason": str(exc)}

        if signal.state == "OK":
            return self._resolve(signal)
        if signal.state not in {"ALARM", "STOPPED"}:
            return {"action": "ignored", "reason": f"state {signal.state}"}
        if signal.source == "ecs-task" and _is_expected_stop(event):
            return {"action": "ignored", "reason": "expected task stop (deployment/scale-in)"}

        existing = self.store.find_open(signal.dedupe_key)
        if not existing and signal.source == "ecs-task":
            # Correlate: a task stopped *because of* an already-open service incident is
            # evidence for that incident, not a new one.
            existing = self._find_related_service_incident(signal)
        if existing:
            existing.add_history("SIGNAL_REPEATED", "system", f"{signal.source} {signal.name} {signal.state}")
            self.store.put(existing)
            return {"action": "deduplicated", "incident_id": existing.incident_id}

        return self._open(signal)

    # ------------------------------------------------------------------
    def _find_related_service_incident(self, signal: Signal) -> Incident | None:
        service = signal.resource.get("service")
        if not service:
            return None
        for category in ("NO_HEALTHY_TARGETS", "UNHEALTHY_TARGETS", "APPLICATION_ERRORS", "HIGH_MEMORY"):
            found = self.store.find_open(f"{category}#{service}")
            if found:
                return found
        return None

    def _open(self, signal: Signal) -> dict[str, Any]:
        evidence = self.collector.collect(signal)
        severity = classify(signal, evidence)

        use_ai = self.config.bedrock_enabled and self.ai_client is not None
        if use_ai and not self.store.consume_ai_quota(self.config.bedrock_daily_limit):
            log.warning("Bedrock daily quota reached - using rules engine")
            use_ai = False
        analyzer = BedrockAnalyzer(
            self.ai_client if use_ai else None, self.config.bedrock_model_id, self.config.bedrock_effort
        )
        analysis = analyzer.analyse(signal, evidence)

        now = utcnow()
        incident = Incident(
            incident_id=Incident.new_id(),
            dedupe_key=signal.dedupe_key,
            title=f"[{severity.value}] {signal.category.value} on {signal.resource.get('service') or signal.name}",
            category=signal.category.value,
            severity=severity.value,
            status=IncidentStatus.OPEN.value,
            created_at=now,
            updated_at=now,
            resource=signal.resource,
            signal={
                "source": signal.source,
                "name": signal.name,
                "state": signal.state,
                "reason": signal.reason,
                "timestamp": signal.timestamp,
            },
            evidence=evidence,
            analysis=analysis.to_dict(),
        )
        incident.add_history("DETECTED", "system", f"{signal.source}: {signal.name}")
        incident.add_history("ANALYSED", analysis.engine, analysis.summary)
        rb = CATALOG.get(analysis.recommended_runbook)
        if rb:
            incident.add_history(
                "REMEDIATION_RECOMMENDED",
                analysis.engine,
                f"{rb.runbook_id} (risk {rb.risk}) - awaiting human approval",
            )
        self.store.put(incident)

        emit_metric("IncidentsOpened", 1, Severity=severity.value, Category=signal.category.value)
        self.notifier.publish(
            f"{incident.title}",
            {
                "incident_id": incident.incident_id,
                "severity": incident.severity,
                "summary": analysis.summary,
                "probable_cause": analysis.probable_cause,
                "recommended_runbook": analysis.recommended_runbook,
                "risk": rb.risk if rb else "n/a",
                "approve_with": f"python scripts/approve.py --incident {incident.incident_id} --decision approve",
                "dashboard": self.config.dashboard_url,
            },
        )
        return {
            "action": "opened",
            "incident_id": incident.incident_id,
            "severity": severity.value,
            "engine": analysis.engine,
            "recommended_runbook": analysis.recommended_runbook,
        }

    def _resolve(self, signal: Signal) -> dict[str, Any]:
        incident = self.store.find_open(signal.dedupe_key)
        if not incident:
            return {"action": "ignored", "reason": "no open incident for recovered signal"}
        incident.status = IncidentStatus.RESOLVED.value
        incident.resolved_at = utcnow()
        incident.add_history("RECOVERED", "system", f"{signal.name} returned to OK: {signal.reason[:200]}")
        self.store.put(incident)
        mttr = _seconds_between(incident.created_at, incident.resolved_at)
        emit_metric("IncidentsResolved", 1, Severity=incident.severity, Category=incident.category)
        emit_metric("TimeToRecoverSeconds", mttr, "Seconds", Severity=incident.severity, Category=incident.category)
        self.notifier.publish(f"RESOLVED {incident.title}", {"incident_id": incident.incident_id, "mttr_seconds": mttr})
        return {"action": "resolved", "incident_id": incident.incident_id, "mttr_seconds": mttr}


def _is_expected_stop(event: dict[str, Any]) -> bool:
    detail = event.get("detail", {})
    reason = (detail.get("stoppedReason") or "").lower()
    stop_code = detail.get("stopCode", "")
    if stop_code == "ServiceSchedulerInitiated" and ("scaling activity" in reason or "deployment" in reason):
        return True
    return stop_code == "UserInitiated"


def _seconds_between(start: str, end: str) -> int:
    return int((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds())


_service: AnalyzerService | None = None


def _build() -> AnalyzerService:
    cfg = Config.from_env()
    session = boto3.session.Session()
    clients = {n: session.client(n) for n in ("cloudwatch", "logs", "ecs", "elbv2")}
    collector = EvidenceCollector(
        clients, {"target_group_arn": cfg.target_group_arn, "app_log_group": cfg.app_log_group}
    )
    store = IncidentStore(session.resource("dynamodb").Table(cfg.table_name))
    ai_client = build_client(cfg.region) if cfg.bedrock_enabled else None
    return AnalyzerService(cfg, store, collector, Notifier(session.client("sns"), cfg.topic_arn), ai_client)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # pragma: no cover - thin wrapper
    global _service
    if _service is None:
        _service = _build()
    result = _service.handle(event)
    log.info("result=%s at=%s", result, datetime.now(UTC).isoformat())
    return result

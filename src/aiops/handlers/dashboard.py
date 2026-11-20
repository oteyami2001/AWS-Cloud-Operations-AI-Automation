"""CloudWatch Dashboard custom widget: incident table, severity/status counts and history.

CloudWatch custom widgets render HTML returned by a Lambda inside the AWS console, so the
dashboard inherits console authentication - no public endpoint is exposed.
"""

from __future__ import annotations

import html
from collections import Counter
from typing import Any

import boto3

from ..models import Incident
from ..platform import Config
from ..store import IncidentStore

SEV_COLOURS = {"SEV1": "#d13212", "SEV2": "#ff9900", "SEV3": "#e6c200", "SEV4": "#879596"}

DOCS = """### AIOps incident table
Renders the most recent incidents from DynamoDB. Parameters: `limit` (default 25)."""


def _badge(text: str, colour: str) -> str:
    return (
        f'<span style="background:{colour};color:#fff;padding:1px 6px;border-radius:3px;'
        f'font-weight:bold">{html.escape(text)}</span>'
    )


def render(incidents: list[Incident]) -> str:
    sev = Counter(i.severity for i in incidents)
    status = Counter(i.status for i in incidents)
    e = html.escape
    out = ['<div style="font-family:Amazon Ember,Arial,sans-serif;font-size:13px">']
    out.append(
        "<p><b>Severity:</b> " + " ".join(f"{_badge(s, SEV_COLOURS[s])} {sev.get(s, 0)}" for s in SEV_COLOURS) + "</p>"
    )
    out.append(
        "<p><b>Status:</b> " + (" &middot; ".join(f"{e(k)}: {v}" for k, v in sorted(status.items())) or "none") + "</p>"
    )
    if not incidents:
        out.append("<p>No incidents recorded.</p></div>")
        return "".join(out)
    out.append(
        '<table class="cwdb-no-default-styles" style="width:100%;border-collapse:collapse">'
        "<tr style='text-align:left;border-bottom:1px solid #ccc'><th>Incident</th><th>Severity</th>"
        "<th>Status</th><th>Created (UTC)</th><th>Probable cause</th><th>Recommendation</th>"
        "<th>Last action</th></tr>"
    )
    for i in incidents:
        analysis = i.analysis or {}
        last = i.history[-1] if i.history else {}
        out.append(
            "<tr style='border-bottom:1px solid #eee;vertical-align:top'>"
            f"<td><code>{e(i.incident_id)}</code><br>{e(i.category)}</td>"
            f"<td>{_badge(i.severity, SEV_COLOURS.get(i.severity, '#879596'))}</td>"
            f"<td>{e(i.status)}</td>"
            f"<td>{e(i.created_at)}</td>"
            f"<td>{e(str(analysis.get('probable_cause', ''))[:240])}<br><small>engine: "
            f"{e(str(analysis.get('engine', '')))} / confidence: {e(str(analysis.get('confidence', '')))}</small></td>"
            f"<td><code>{e(str(analysis.get('recommended_runbook', '')))}</code></td>"
            f"<td>{e(str(last.get('action', '')))}<br><small>{e(str(last.get('actor', ''))[-60:])}</small></td>"
            "</tr>"
        )
    out.append("</table></div>")
    return "".join(out)


def handler(event: dict[str, Any], context: Any) -> str:  # pragma: no cover - AWS wiring
    if event.get("describe"):
        return DOCS
    cfg = Config.from_env()
    # Custom widget params (from the dashboard JSON) arrive as top-level event keys.
    limit = int(event.get("limit", 25))
    store = IncidentStore(boto3.resource("dynamodb").Table(cfg.table_name))
    return render(store.list_recent(limit=min(limit, 100)))

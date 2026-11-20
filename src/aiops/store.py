"""DynamoDB persistence for incidents (table schema in terraform/modules/aiops/dynamodb.tf)."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from boto3.dynamodb.conditions import Key

from .models import OPEN_STATUSES, Incident


def _to_ddb(value: Any) -> Any:
    # DynamoDB rejects floats; round-trip through JSON with Decimal.
    return json.loads(json.dumps(value, default=str), parse_float=Decimal)


def _from_ddb(value: Any) -> Any:
    if isinstance(value, list):
        return [_from_ddb(v) for v in value]
    if isinstance(value, dict):
        return {k: _from_ddb(v) for k, v in value.items()}
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value


class IncidentStore:
    def __init__(self, table: Any):
        self.table = table

    def put(self, incident: Incident) -> None:
        self.table.put_item(Item=_to_ddb(incident.to_item()))

    def get(self, incident_id: str) -> Incident | None:
        item = self.table.get_item(Key={"incident_id": incident_id}).get("Item")
        return Incident.from_item(_from_ddb(item)) if item else None

    def find_open(self, dedupe_key: str) -> Incident | None:
        resp = self.table.query(
            IndexName="by_dedupe_key",
            KeyConditionExpression=Key("dedupe_key").eq(dedupe_key),
            ScanIndexForward=False,
            Limit=10,
        )
        for item in resp.get("Items", []):
            if item.get("status") in OPEN_STATUSES:
                return Incident.from_item(_from_ddb(item))
        return None

    def find_by_execution(self, execution_id: str) -> Incident | None:
        resp = self.table.query(
            IndexName="by_execution_id", KeyConditionExpression=Key("execution_id").eq(execution_id), Limit=1
        )
        items = resp.get("Items", [])
        return Incident.from_item(_from_ddb(items[0])) if items else None

    def set_execution_id(self, incident_id: str, execution_id: str) -> None:
        self.table.update_item(
            Key={"incident_id": incident_id},
            UpdateExpression="SET execution_id = :e",
            ExpressionAttributeValues={":e": execution_id},
        )

    def list_recent(self, limit: int = 50) -> list[Incident]:
        # Low-volume table (portfolio scale): a bounded scan sorted client-side is cheaper than a GSI.
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"Limit": 200}
        while True:
            resp = self.table.scan(**kwargs)
            items.extend(i for i in resp.get("Items", []) if str(i.get("incident_id", "")).startswith("INC-"))
            if "LastEvaluatedKey" not in resp or len(items) >= 1000:
                break
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        items.sort(key=lambda i: i.get("created_at", ""), reverse=True)
        return [Incident.from_item(_from_ddb(i)) for i in items[:limit]]

    def consume_ai_quota(self, daily_limit: int) -> bool:
        """Atomically count Bedrock calls per UTC day; returns False once the limit is reached."""
        if daily_limit <= 0:
            return False
        day = datetime.now(UTC).strftime("%Y-%m-%d")
        try:
            self.table.update_item(
                Key={"incident_id": f"quota#bedrock#{day}"},
                UpdateExpression="ADD calls :one SET expires_at = :ttl",
                ConditionExpression="attribute_not_exists(calls) OR calls < :limit",
                ExpressionAttributeValues={
                    ":one": 1,
                    ":limit": daily_limit,
                    ":ttl": int(datetime.now(UTC).timestamp()) + 3 * 86400,
                },
            )
            return True
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            return False

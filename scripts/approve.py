#!/usr/bin/env python3
"""Approve or reject an incident's recommended remediation (human-in-the-loop).

Sends a SigV4-signed request to the IAM-authenticated remediation Function URL using your current
AWS credentials - assume the operator role first:

    aws sts assume-role ... (or a profile with role_arn = <operator_role_arn> + mfa_serial)
    python scripts/approve.py --incident INC-20261120-ab12cd34 --decision approve \
        --justification "Tasks unhealthy, image unchanged; replacing tasks."

Use --show to print the incident's analysis before deciding.
"""

from __future__ import annotations

import argparse
import json
import subprocess  # nosec B404 - fixed argv, used only to read terraform outputs
import sys
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


def tf_output(name: str) -> str:
    out = subprocess.run(  # nosec B603 B607 - fixed command, no shell
        ["terraform", "-chdir=terraform/envs/dev", "output", "-raw", name],
        check=True,
        capture_output=True,
        text=True,
    )
    return out.stdout.strip()


def show(table: str, incident_id: str) -> None:
    item = boto3.resource("dynamodb").Table(table).get_item(Key={"incident_id": incident_id}).get("Item")
    if not item:
        sys.exit(f"incident {incident_id} not found")
    a = item.get("analysis", {})
    print(f"{item['incident_id']}  {item['severity']}  {item['status']}  {item['title']}")
    print(f"engine:      {a.get('engine')}  (confidence {a.get('confidence')})")
    print(f"summary:     {a.get('summary')}")
    print(f"cause:       {a.get('probable_cause')}")
    print(f"recommended: {a.get('recommended_runbook')}  - {a.get('rationale')}")
    for i, step in enumerate(a.get("troubleshooting_steps", []), 1):
        print(f"  {i}. {step}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--incident", required=True)
    p.add_argument("--decision", choices=["approve", "reject"])
    p.add_argument("--justification", default="")
    p.add_argument("--runbook", help="override the recommended runbook (must still be approved for the category)")
    p.add_argument("--url", help="remediation Function URL (default: terraform output)")
    p.add_argument("--table", help="incident table (default: terraform output)")
    p.add_argument("--show", action="store_true")
    args = p.parse_args()

    if args.show:
        show(args.table or tf_output("incident_table"), args.incident)
        if not args.decision:
            return
    if not args.decision:
        p.error("--decision is required unless --show is used alone")

    url = args.url or tf_output("remediation_url")
    if not url.startswith("https://"):
        sys.exit("remediation URL must be https://")
    body = {"incident_id": args.incident, "decision": args.decision, "justification": args.justification}
    if args.runbook:
        body["runbook_id"] = args.runbook

    session = boto3.session.Session()
    creds = session.get_credentials().get_frozen_credentials()
    req = AWSRequest(method="POST", url=url, data=json.dumps(body), headers={"Content-Type": "application/json"})
    SigV4Auth(creds, "lambda", session.region_name or "us-east-2").add_auth(req)
    http_req = urllib.request.Request(url, data=req.body, headers=dict(req.headers), method="POST")  # noqa: S310
    try:
        with urllib.request.urlopen(http_req, timeout=30) as resp:  # nosec B310 - https Function URL
            print(resp.status, resp.read().decode())
    except urllib.error.HTTPError as e:
        print(e.code, e.read().decode())
        sys.exit(1)


if __name__ == "__main__":
    main()

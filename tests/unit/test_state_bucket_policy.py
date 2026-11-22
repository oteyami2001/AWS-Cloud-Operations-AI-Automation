"""Semantic regression test for the Terraform state-bucket policy.

The policy JSON is read from the SAME template Terraform deploys
(terraform/bootstrap/policies/state_bucket_policy.json.tftpl) and evaluated against the exact S3
requests the Terraform S3 backend makes (verified in hashicorp/terraform v1.17.2,
internal/backend/remote-state/s3/client.go: `put` and `lockWithFile` send
`ServerSideEncryption: "AES256"` when `encrypt = true`; unlock uses DeleteObject; the state upload
goes through the multipart-capable `manager.Uploader`).

The evaluator implements the condition semantics documented in the AWS IAM User Guide
("Condition operators"):
  * a key missing from the request context does not match, so the condition is FALSE, except for
    negated operators (StringNot*, ArnNot*, ...), which are TRUE;
  * ...IfExists: "If the key is not present, evaluate the condition element as true";
  * Null: "true" means the key is absent, "false" means the key is present;
  * several values for one key are ORed; several keys/operators in one Condition are ANDed.
Only explicit Deny statements are evaluated. Allows come from the IAM roles, not from this policy.
"""

from __future__ import annotations

import fnmatch
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "terraform" / "bootstrap" / "policies" / "state_bucket_policy.json.tftpl"
BUCKET = "arn:aws:s3:::aiops-tfstate-123456789012-us-east-2"
STATE_KEY = f"{BUCKET}/envs/dev/terraform.tfstate"
LOCK_KEY = f"{BUCKET}/envs/dev/terraform.tfstate.tflock"
SSE = "s3:x-amz-server-side-encryption"
SSE_C = "s3:x-amz-server-side-encryption-customer-algorithm"


# --------------------------------------------------------------------------------------------
# Minimal IAM condition evaluator (only what this policy uses, strict on anything else)
# --------------------------------------------------------------------------------------------
def _as_list(v):
    return v if isinstance(v, list) else [v]


def _operator_matches(op: str, key: str, expected, ctx: dict) -> bool:
    values = [str(v) for v in _as_list(expected)]
    present = key in ctx
    if op == "Null":
        want_absent = values[0].lower() == "true"
        return (not present) if want_absent else present
    if_exists = op.endswith("IfExists")
    base = op[: -len("IfExists")] if if_exists else op
    negated = base in {"StringNotEquals", "StringNotLike", "ArnNotEquals", "ArnNotLike"}
    if not present:
        if if_exists:
            return True  # "If the key is not present, evaluate the condition element as true"
        return negated  # missing key: no match -> False, except negated operators -> True
    actual = str(ctx[key])
    if base == "Bool":
        return actual.lower() in [v.lower() for v in values]
    if base == "StringEquals":
        return actual in values
    if base == "StringNotEquals":
        return actual not in values
    raise NotImplementedError(f"operator {op} not supported by this test evaluator")


def _condition_matches(condition: dict, ctx: dict) -> bool:
    return all(_operator_matches(op, key, exp, ctx) for op, block in condition.items() for key, exp in block.items())


def explicitly_denied(policy: dict, action: str, resource: str, ctx: dict) -> list[str]:
    """Return the Sids of Deny statements that apply to the request (empty list = not denied)."""
    hits = []
    for st in policy["Statement"]:
        if st["Effect"] != "Deny" or st.get("Principal") != "*":
            continue
        if not any(fnmatch.fnmatchcase(action, a) for a in _as_list(st["Action"])):
            continue
        if not any(fnmatch.fnmatchcase(resource, r) for r in _as_list(st["Resource"])):
            continue
        if _condition_matches(st.get("Condition", {}), ctx):
            hits.append(st.get("Sid", "?"))
    return hits


def render(template: str) -> dict:
    return json.loads(template.replace("${bucket_arn}", BUCKET))


@pytest.fixture(scope="module")
def policy() -> dict:
    return render(TEMPLATE.read_text())


TLS = {"aws:SecureTransport": "true"}

# (description, action, resource, request context, expected denied?)
SCENARIOS = [
    ("backend state PutObject, encrypt=true", "s3:PutObject", STATE_KEY, {**TLS, SSE: "AES256"}, False),
    ("backend lock-file PutObject, encrypt=true", "s3:PutObject", LOCK_KEY, {**TLS, SSE: "AES256"}, False),
    ("backend PutObject with encrypt unset (bucket default AES-256)", "s3:PutObject", STATE_KEY, dict(TLS), False),
    ("multipart UploadPart (no SSE header on parts)", "s3:PutObject", STATE_KEY, dict(TLS), False),
    ("state read", "s3:GetObject", STATE_KEY, dict(TLS), False),
    ("unlock: delete lock file", "s3:DeleteObject", LOCK_KEY, dict(TLS), False),
    ("list bucket", "s3:ListBucket", BUCKET, dict(TLS), False),
    ("upload requesting SSE-KMS", "s3:PutObject", STATE_KEY, {**TLS, SSE: "aws:kms"}, True),
    ("upload requesting DSSE-KMS", "s3:PutObject", STATE_KEY, {**TLS, SSE: "aws:kms:dsse"}, True),
    ("upload with SSE-C customer key", "s3:PutObject", STATE_KEY, {**TLS, SSE_C: "AES256"}, True),
    ("any request over plain HTTP", "s3:GetObject", STATE_KEY, {"aws:SecureTransport": "false"}, True),
    (
        "PutObject over plain HTTP even with AES256",
        "s3:PutObject",
        STATE_KEY,
        {"aws:SecureTransport": "false", SSE: "AES256"},
        True,
    ),
]


@pytest.mark.parametrize(("desc", "action", "resource", "ctx", "denied"), SCENARIOS, ids=[s[0] for s in SCENARIOS])
def test_state_bucket_policy_semantics(policy, desc, action, resource, ctx, denied):
    hits = explicitly_denied(policy, action, resource, ctx)
    assert bool(hits) is denied, f"{desc}: expected denied={denied}, deny statements matched={hits}"


# --------------------------------------------------------------------------------------------
# Evaluator self-checks against the documented AWS semantics, and the regressions we hit
# --------------------------------------------------------------------------------------------
def _single_deny(condition: dict | None) -> dict:
    st = {"Sid": "X", "Effect": "Deny", "Principal": "*", "Action": "s3:PutObject", "Resource": f"{BUCKET}/*"}
    if condition is not None:
        st["Condition"] = condition
    return {"Statement": [st]}


def test_evaluator_matches_documented_ifexists_semantics():
    # AWS: "If you are using an "Effect": "Deny" element with a negated condition operator like
    # StringNotEqualsIfExists, the request is still denied even if the tag is missing."
    p = _single_deny({"StringNotEqualsIfExists": {SSE: "AES256"}})
    assert explicitly_denied(p, "s3:PutObject", STATE_KEY, dict(TLS))
    assert not explicitly_denied(p, "s3:PutObject", STATE_KEY, {**TLS, SSE: "AES256"})


def test_evaluator_null_semantics():
    assert explicitly_denied(_single_deny({"Null": {SSE: "true"}}), "s3:PutObject", STATE_KEY, dict(TLS))
    assert not explicitly_denied(_single_deny({"Null": {SSE: "false"}}), "s3:PutObject", STATE_KEY, dict(TLS))


@pytest.mark.parametrize(
    "bad_condition",
    [
        None,  # unconditional Deny (the manual-edit regression)
        {"StringNotEqualsIfExists": {SSE: "AES256"}},  # commit b194ab0
        {"StringNotEquals": {SSE: "AES256"}},  # negated operator without a Null guard
    ],
    ids=["unconditional", "StringNotEqualsIfExists", "StringNotEquals-without-Null"],
)
def test_known_bad_policies_would_block_default_encrypted_uploads(bad_condition):
    """Proves the test catches each regression: all three deny an upload without an SSE header."""
    assert explicitly_denied(_single_deny(bad_condition), "s3:PutObject", STATE_KEY, dict(TLS))


def test_every_deny_is_conditional_and_template_is_strict_json(policy):
    for st in policy["Statement"]:
        assert st["Effect"] == "Deny"
        assert st.get("Condition"), f"{st['Sid']}: unconditional Deny would lock Terraform out of its state"
    assert "${" not in json.dumps(policy), "unrendered template variable"

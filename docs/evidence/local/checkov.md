# Checkov IaC scan - LOCAL

`checkov -d terraform --framework terraform` (3.4.6), 2026-11-20T22:24:50Z

```
Passed checks: 406, Failed checks: 0, Skipped checks: 38


```

Every skip is inline with a justification (`grep -rn 'checkov:skip' terraform`) and reviewed in [docs/security-review.md](../../security-review.md#5-review-of-the-38-checkov-skips).

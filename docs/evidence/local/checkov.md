# Checkov IaC scan - LOCAL

`checkov -d terraform --framework terraform` (3.4.6), 2026-11-20T15:55:20Z

```
terraform scan results:

Passed checks: 362, Failed checks: 0, Skipped checks: 38


```

Every skip is inline in the Terraform with a justification (`grep -rn 'checkov:skip' terraform`).

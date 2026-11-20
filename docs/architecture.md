# Architecture

## Component view

```mermaid
flowchart TB
    subgraph Workload["Monitored workload (terraform/modules/workload)"]
        ALB["Application Load Balancer<br/>/health check"]
        ECS["ECS Fargate service<br/>sample app + fault injection"]
        LOGS[("CloudWatch Logs<br/>app log group (KMS)")]
        ALB --> ECS
        ECS --> LOGS
    end

    subgraph Detect["Detection (modules/monitoring)"]
        ALARMS["CloudWatch alarms<br/>cpu-high · memory-high · alb-5xx<br/>app-errors · unhealthy-targets · no-healthy-targets"]
        MF["Log metric filter<br/>ERROR / Exception"]
        LOGS --> MF --> ALARMS
        ALB -. metrics .-> ALARMS
        ECS -. metrics .-> ALARMS
    end

    subgraph Route["Event routing (modules/aiops/events.tf)"]
        EB{{"EventBridge rules<br/>alarm state · ECS task STOPPED · SSM status"}}
        DLQ[["SQS DLQ (KMS)"]]
        EB -. failed deliveries .-> DLQ
    end

    subgraph Analyze["Incident analysis (src/aiops)"]
        AN["Lambda: incident-analyzer<br/>normalise → dedupe → evidence → severity"]
        BR["Amazon Bedrock<br/>Claude via Bedrock (optional)"]
        RULES["Deterministic rules engine<br/>(fallback, always available)"]
        DDB[("DynamoDB incidents<br/>KMS · PITR")]
        SNS["SNS alerts (KMS)"]
        AN -- "redacted evidence,<br/>schema-constrained output" --> BR
        AN --> RULES
        AN --> DDB
        AN --> SNS
    end

    subgraph Remediate["Human-approved remediation (modules/remediation)"]
        OP(["Operator<br/>(IAM role + MFA)"])
        URL["Lambda: remediation-approval<br/>Function URL, AWS_IAM auth"]
        SSM["SSM Automation<br/>4 approved runbooks"]
        SR(["Senior approver<br/>(2nd approval, HIGH risk)"])
        ST["Lambda: remediation-status"]
        OP -- "SigV4: approve / reject<br/>+ justification" --> URL
        URL -- "StartAutomationExecution<br/>(allowlisted docs only)" --> SSM
        SR -- "aws:approve signal" --> SSM
        SSM -- "UpdateService<br/>(this service only)" --> ECS
    end

    subgraph View["Operations dashboard (modules/dashboard)"]
        DASH["CloudWatch dashboard"]
        WID["Lambda: dashboard-widget<br/>incident table HTML"]
        DASH --> WID --> DDB
    end

    ALARMS -- "state change" --> EB
    ECS -- "task state change" --> EB
    EB --> AN
    SSM -- "execution status" --> EB
    EB --> ST --> DDB
    URL --> DDB
    SNS --> OP
```

## Incident lifecycle (sequence)

```mermaid
sequenceDiagram
    autonumber
    participant CW as CloudWatch alarm
    participant EB as EventBridge
    participant AN as Analyzer Lambda
    participant BR as Bedrock (optional)
    participant DB as DynamoDB
    participant H as Operator (human)
    participant AP as Approval Lambda
    participant SSM as SSM Automation
    participant ST as Status Lambda

    CW->>EB: OK → ALARM
    EB->>AN: CloudWatch Alarm State Change
    AN->>DB: open incident for dedupe key?
    alt already open
        AN->>DB: append SIGNAL_REPEATED (no new analysis, no new Bedrock call)
    else new incident
        AN->>AN: collect evidence (ECS, target health, logs, metrics) + redact secrets
        AN->>AN: severity (deterministic)
        AN->>BR: evidence (untrusted block) + approved runbook ids
        BR-->>AN: JSON {summary, cause, steps, recommended_runbook ∈ enum}
        AN->>AN: validate; on any failure → rules engine
        AN->>DB: incident OPEN + history
        AN-->>H: SNS: summary, cause, recommendation, approve command
    end
    H->>AP: SigV4 POST {decision, justification}
    AP->>AP: verify IAM caller ARN, status, catalog, category
    AP->>SSM: StartAutomationExecution(approved doc, params from incident)
    AP->>DB: REMEDIATING + approver identity
    opt HIGH risk runbook
        SSM-->>H: waits at aws:approve for senior-approver role
    end
    SSM->>EB: execution status Success / Failed
    EB->>ST: status event
    ST->>DB: RESOLVED / REMEDIATION_FAILED
    CW->>EB: ALARM → OK
    EB->>AN: state change
    AN->>DB: RESOLVED (records time-to-recover metric)
```

## Incident state machine

```mermaid
stateDiagram-v2
    [*] --> OPEN: alarm / task stop
    OPEN --> REMEDIATING: operator approves (SSM started)
    OPEN --> REJECTED: operator rejects
    OPEN --> RESOLVED: alarm returns to OK (self-healed)
    REJECTED --> REMEDIATING: operator approves later
    REJECTED --> RESOLVED: alarm OK
    REMEDIATING --> RESOLVED: SSM Success or alarm OK
    REMEDIATING --> REMEDIATION_FAILED: SSM Failed / TimedOut / Rejected
    REMEDIATION_FAILED --> REMEDIATING: operator retries
    REMEDIATION_FAILED --> RESOLVED: alarm OK
    RESOLVED --> [*]
```

## Trust boundaries

| Boundary | Control |
|---|---|
| Log lines / evidence → model | Treated as untrusted data in a delimited block; secrets redacted first; output is a JSON schema with an **enum** of approved runbook ids; re-validated in code. |
| Model output → infrastructure | No path exists. The analyzer role has no SSM/ECS write permissions (asserted by `terraform test`). |
| Human → remediation | IAM-authenticated Function URL; approver identity is the verified caller ARN, not the request body; justification required. |
| Remediation → AWS | Only 4 allowlisted SSM documents; parameters built from the incident's resource ids; SSM role limited to one ECS service; desired counts bounded by `allowedValues`. |
| HIGH risk | `aws:approve` step inside the SSM document → a second principal (senior-approver role) must approve. |

## Repository structure

```
.
├── src/
│   ├── aiops/                  # Lambda code (one package, four handlers)
│   │   ├── events.py           # EventBridge → Signal normalisation
│   │   ├── evidence.py         # read-only evidence collectors + secret redaction
│   │   ├── severity.py         # deterministic severity
│   │   ├── rules.py            # deterministic root-cause playbook (fallback)
│   │   ├── ai.py               # Bedrock analysis, schema-constrained, validated
│   │   ├── runbooks.py         # APPROVED runbook catalog (allowlist)
│   │   ├── store.py            # DynamoDB repository + Bedrock daily quota
│   │   └── handlers/           # analyzer · remediation · status · dashboard
│   └── sample_app/             # monitored workload with fault injection + Dockerfile
├── terraform/
│   ├── bootstrap/              # state bucket, lock table, GitHub OIDC roles
│   ├── envs/dev/               # composition root (+ offline terraform tests)
│   └── modules/                # security · network · workload · monitoring · aiops · remediation · dashboard
├── tests/                      # pytest unit + integration (moto) tests, event fixtures
├── scripts/                    # build, approve, simulate, load test, offline demo
├── docs/                       # ADR, architecture, cost, security, runbooks, evidence
└── .github/workflows/          # ci.yml (no AWS), deploy.yml (manual, approval-gated)
```

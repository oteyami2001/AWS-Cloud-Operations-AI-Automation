# GitHub Actions OIDC federation: short-lived credentials only, no stored AWS keys.
#
#   role                         | trusted OIDC subject                                   | can do
#   -----------------------------|--------------------------------------------------------|------------------------------
#   <project>-github-plan        | main branch, pull requests                             | read-only describe + state lock
#   <project>-github-apply       | ONLY the "aws-dev" GitHub environment (required review)| create/update/destroy envs/dev
#   <project>-github-image-push  | main branch                                            | push to the one ECR repository
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate against its trusted CA store; this value is retained for the API.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  state_objects     = "${aws_s3_bucket.state.arn}/envs/${var.environment}/*"
  role_arn_prefix   = "arn:${local.partition}:iam::${local.account}:role/${local.workload_prefix}"
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan  = ["${local.oidc_sub_prefix}:ref:refs/heads/main", "${local.oidc_sub_prefix}:pull_request"]
    apply = ["${local.oidc_sub_prefix}:environment:${var.github_deploy_environment}"]
    image = ["${local.oidc_sub_prefix}:ref:refs/heads/main"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Exact subjects (StringEquals, no wildcards): other repos, forks and other branches are rejected.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# ---------------------------------------------------------------------------------------------
# State access (shared by plan and apply)
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "state_access" {
  statement {
    # The S3 backend lists keys (workspace discovery) during init; listing exposes key names only.
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "ReadWriteStateAndLockFile"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_objects]
  }
}

# ---------------------------------------------------------------------------------------------
# Plan role: describe-only access to the services this project uses (NOT ReadOnlyAccess, which can
# read data in every S3 bucket / DynamoDB table in the account).
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "plan" {
  # checkov:skip=CKV_AWS_356:Plan must refresh every resource type; statement is metadata Describe/List/Get only (no data reads - asserted by terraform test).
  source_policy_documents = [data.aws_iam_policy_document.state_access.json]

  # Metadata reads only. Deliberately EXCLUDED: s3:GetObject (other buckets), dynamodb Scan/Query/
  # GetItem, logs GetLogEvents/FilterLogEvents, sqs ReceiveMessage, ssm GetParameter*, ecr layer
  # downloads, kms Decrypt, secretsmanager GetSecretValue (except the one demo token below).
  statement {
    sid = "DescribeProjectServices"
    actions = [
      "ec2:Describe*", "elasticloadbalancing:Describe*",
      "ecs:Describe*", "ecs:List*",
      "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy",
      "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
      "cloudwatch:Describe*", "cloudwatch:GetDashboard", "cloudwatch:List*",
      "events:Describe*", "events:List*",
      "lambda:Get*", "lambda:List*",
      "dynamodb:Describe*", "dynamodb:ListTagsOfResource", "dynamodb:ListTables",
      "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueues", "sqs:ListQueueTags",
      "sns:GetTopicAttributes", "sns:GetSubscriptionAttributes", "sns:List*",
      "ssm:DescribeDocument*", "ssm:GetDocument", "ssm:ListDocument*", "ssm:ListTagsForResource",
      "kms:Describe*", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:List*",
      "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecret*",
      "iam:Get*", "iam:List*",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  # Refreshing aws_secretsmanager_secret_version reads the version via GetSecretValue. Scoped to the
  # demo fault-injection token only, decrypted only through Secrets Manager.
  # The fault token is an EPHEMERAL value (aws_secretsmanager_random_password), opened during plan
  # as well as apply. GetRandomPassword only returns a random string: it reads/writes no secret and
  # does not support resource-level permissions.
  statement {
    sid       = "GenerateEphemeralRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "RefreshDemoFaultTokenVersion"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account}:secret:${var.project}-${var.environment}/sample-app/fault-token-*"]
  }
  statement {
    sid       = "DecryptViaSecretsManagerOnly"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${local.partition}:kms:${var.region}:${local.account}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# ---------------------------------------------------------------------------------------------
# Apply role: only the services in envs/dev, only in var.region, IAM only for project-prefixed
# roles that carry the workload permissions boundary.
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "apply" {
  # checkov:skip=CKV_AWS_356:Create* APIs for these services do not support resource-level scoping; constrained by aws:RequestedRegion instead.
  # checkov:skip=CKV_AWS_111:Same as above - write access is service- and region-scoped; IAM writes are name- and boundary-scoped.
  # checkov:skip=CKV_AWS_109:Same as above.
  source_policy_documents = [data.aws_iam_policy_document.state_access.json]

  statement {
    sid = "ProjectServicesInRegion"
    actions = [
      # networking (VPC only - cannot launch EC2 instances)
      "ec2:Describe*", "ec2:*Vpc*", "ec2:*Subnet*", "ec2:*InternetGateway*", "ec2:*RouteTable*", "ec2:*Route",
      "ec2:*SecurityGroup*", "ec2:*FlowLogs", "ec2:CreateTags", "ec2:DeleteTags",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListTagsForResource",
      "logs:*", "cloudwatch:*", "events:*", "lambda:*", "dynamodb:*", "sqs:*", "sns:*",
      "ssm:*Document*", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
      "kms:*", "secretsmanager:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "Identity"
    actions   = ["sts:GetCallerIdentity", "iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Role creation and every permission-changing call REQUIRE the workload boundary.
  statement {
    sid       = "ManageProjectRolesWithBoundaryOnly"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = ["${local.role_arn_prefix}*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "ManageProjectRolesMetadata"
    actions = [
      "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy", "iam:PassRole",
    ]
    resources = ["${local.role_arn_prefix}*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account}:role/aws-service-role/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid    = "ExplicitDenies"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary", "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
      "organizations:*", "account:*", "cloudtrail:StopLogging", "cloudtrail:DeleteTrail",
      "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NoChangesToCiRolesOrBoundary"
    effect = "Deny"
    actions = [
      "iam:Create*", "iam:Delete*", "iam:Put*", "iam:Update*", "iam:Attach*", "iam:Detach*",
      "iam:Tag*", "iam:Untag*", "iam:Set*", "iam:PassRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account}:role/${var.project}-github-*", aws_iam_policy.workload_boundary.arn]
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.project}-github-apply"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["apply"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# ---------------------------------------------------------------------------------------------
# Image push role: push to the single ECR repository only.
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "image_push" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken does not support resource-level permissions
  }
  statement {
    sid = "PushToSampleAppRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role" "image_push" {
  name                 = "${var.project}-github-image-push"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["image"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "image_push" {
  name   = "image-push"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}

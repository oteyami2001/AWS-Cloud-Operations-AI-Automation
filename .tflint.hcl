plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.34.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Module variables intentionally rely on callers for types/descriptions in a few places.
rule "terraform_documented_variables" {
  enabled = false
}

rule "terraform_documented_outputs" {
  enabled = false
}

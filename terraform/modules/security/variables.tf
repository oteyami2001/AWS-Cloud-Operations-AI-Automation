variable "name_prefix" {
  description = "Prefix for all resource names, e.g. aiops-dev."
  type        = string
}

variable "fault_token_version" {
  description = "Increment to rotate the fault-injection token (write-only secret)."
  type        = number
  default     = 1
}

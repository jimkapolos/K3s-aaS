
terraform {
  required_providers {
    kubernetes = {
      source = "opentofu/kubernetes"
      version = "2.36.0"
    }
  }
}



variable "vm_count" {
  description = "Number of VMs to deploy"
  type        = number
  default     = 2
}

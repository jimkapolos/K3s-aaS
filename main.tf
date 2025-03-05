terraform {
  required_providers {
    kubernetes = {
      source = "opentofu/kubernetes"
      version = "2.36.0"
    }
  }
}



provider "kubernetes" {
  config_path    = "~/.kube/config"
}

resource "vm_instance" "example" {
  count = var.vm_count
  # Ρυθμίσεις για το VM (π.χ. image, τύπος, περιοχή, κλπ.)
}

variable "vm_count" {
  description = "Number of VMs to deploy"
  type        = number
  default     = 2
}

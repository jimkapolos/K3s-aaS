terraform {
  required_providers {
    kubernetes = {
      source = "opentofu/kubernetes"
      version = "2.36.0"
    }
  }
}

provider "kubernetes" {
  host = "https://192.168.188.201:6443"

  config_path = "~/.kube/config"
}

variable "vm_count" {
  description = "Number of VMs to deploy"
  type        = number
  default     = 2
}

resource "kubernetes_pod" "example" {
  metadata {
    name = "example-pod"
  }
  spec {
    container {
      name  = "nginx"
      image = "nginx:latest"
    }
  }
}

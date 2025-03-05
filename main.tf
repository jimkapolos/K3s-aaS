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

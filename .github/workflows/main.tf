resource "vm_instance" "example" {
  count = var.vm_count
  # Ρυθμίσεις για το VM (π.χ. image, τύπος, περιοχή, κλπ.)
}

variable "vm_count" {
  description = "Number of VMs to deploy"
  type        = number
  default     = 2
}

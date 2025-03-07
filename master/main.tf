# master/main.tf
terraform {
  required_providers {
    kubevirt = {
      source  = "kubevirt/kubevirt"
      version = "0.0.1"
    }
  }
}

provider "kubevirt" {
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubevirt_virtual_machine" "github-action" {
  metadata {
    name      = "github-action"
    namespace = "default"
    annotations = {
      "kubevirt.io/domain" = "github-action"
    }
  }
  # ... rest of your existing configuration
}

# Add a null_resource to wait for the VM to be ready and get the IP and token
resource "null_resource" "get_master_info" {
  depends_on = [kubevirt_virtual_machine.github-action]

  # This will run after the VM is created
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for the VM to be ready
      echo "Waiting for VM to be ready..."
      kubectl wait --for=condition=Ready vm/github-action --timeout=300s
      
      # Wait a bit more for K3s to be fully initialized
      sleep 120
      
      # Get the VM IP
      VM_IP=$(kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}')
      
      # Wait until SSH is available
      until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 apel@$VM_IP "echo SSH is up"; do
        echo "Waiting for SSH to be available..."
        sleep 10
      done
      
      # Get the K3s token
      K3S_TOKEN=$(ssh -o StrictHostKeyChecking=no apel@$VM_IP "sudo cat /var/lib/rancher/k3s/server/node-token")
      
      # Save the information to files that will be used by the output
      echo $VM_IP > vm_ip.txt
      echo $K3S_TOKEN > k3s_token.txt
    EOT
  }
}

# Read the IP and token from the files created by the null_resource
data "local_file" "vm_ip" {
  depends_on = [null_resource.get_master_info]
  filename   = "vm_ip.txt"
}

data "local_file" "k3s_token" {
  depends_on = [null_resource.get_master_info]
  filename   = "k3s_token.txt"
}

# Output the IP and token
output "master_ip" {
  value = trimspace(data.local_file.vm_ip.content)
}

output "k3s_token" {
  value     = trimspace(data.local_file.k3s_token.content)
  sensitive = true  # Mark as sensitive to prevent showing in logs
}

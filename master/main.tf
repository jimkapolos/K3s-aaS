# Add this to your existing Terraform configuration

data "kubernetes_pod" "github_action_pod" {
  depends_on = [kubevirt_virtual_machine.github-action]
  
  metadata {
    namespace = "default"
    wait_for_conditions = ["Ready"]
  }
  
  # Use the label selector matching your VM
  selector {
    match_labels = {
      "kubevirt.io/domain" = "github-action"
    }
  }
}

# Get K3s token from the VM (may require a provisioner or custom script)
resource "null_resource" "get_k3s_token" {
  depends_on = [kubevirt_virtual_machine.github-action]
  
  provisioner "local-exec" {
    # Wait for VM to fully initialize
    command = <<-EOT
      sleep 180
      # Use the NodePort to SSH into the VM and grab the token
      TOKEN=$(sshpass -p "apel1234" ssh -o StrictHostKeyChecking=no -p 30021 apel@$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') "sudo cat /var/lib/rancher/k3s/server/node-token")
      echo "vm_ip = \"${data.kubernetes_pod.github_action_pod.status[0].pod_ip}\"" > vm_details.tf
      echo "k3s_token = \"$TOKEN\"" >> vm_details.tf
    EOT
  }
}

output "vm_ip" {
  value = data.kubernetes_pod.github_action_pod.status[0].pod_ip
  description = "IP address of the github-action VM"
}

output "node_ssh_access" {
  value = "ssh -p 30021 apel@NODE_IP"
  description = "Command to SSH into the VM (replace NODE_IP with your node's IP)"
}

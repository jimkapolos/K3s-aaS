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

# First, let's add a data source to get the master node's IP
data "kubernetes_pod" "master_pod" {
  metadata {
    namespace = "default"
  }
  
  selector {
    match_labels = {
      "kubevirt.io/domain" = "github-action"
    }
  }
}

resource "kubevirt_virtual_machine" "github-action-agent" {
  metadata {
    name      = "github-action-agent"
    namespace = "default"
    annotations = {
      "kubevirt.io/domain" = "github-action-agent"
    }
  }
  spec {
    run_strategy = "Always"
    data_volume_templates {
      metadata {
        name      = "ubuntu-disk5"
        namespace = "default"
      }
      spec {
        pvc {
          access_modes = ["ReadWriteOnce"]
          resources {
            requests = {
              storage = "10Gi"
            }
          }
        }
        source {
          http {
            url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
          }
        }
      }
    }
    template {
      metadata {
        labels = {
          "kubevirt.io/domain" = "github-action-agent"
        }
      }
      spec {
        domain {
          devices {
            disk {
              name = "rootdisk"
              disk_device {
                disk {
                  bus = "virtio"
                }
              }
            }
            disk {
              name = "cloudinitdisk"
              disk_device {
                disk {
                  bus = "virtio"
                }
              }
            }
            interface {
              name                     = "default"
              interface_binding_method = "InterfaceMasquerade"
            }
          }
          resources {
            requests = {
              cpu    = "2"
              memory = "2Gi"
            }
          }
        }
        network {
          name = "default"
          network_source {
            pod {}
          }
        }
        volume {
          name = "rootdisk"
          volume_source {
            data_volume {
              name = "ubuntu-disk5"
            }
          }
        }
        volume {
          name = "cloudinitdisk"
          volume_source {
            cloud_init_config_drive {
              user_data = <<EOF
#cloud-config
ssh_pwauth: true
users:
  - name: apel
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
chpasswd:
  list: |
    apel:apel1234
  expire: false
write_files:
  - path: /usr/local/bin/k3s-agent-setup.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      echo "apel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
      sudo apt-get update
      sudo apt-get install -y sshpass
      
      # Get master node IP - this uses the node IP where the service is exposed
      MASTER_NODE_IP=$(ip route get 1 | awk '{print $7;exit}' | cut -d. -f1-3).201
      
      # Get K3S token from master node
      K3S_TOKEN=$(sshpass -p "apel1234" ssh -o StrictHostKeyChecking=no -p 30021 apel@$MASTER_NODE_IP "sudo cat /var/lib/rancher/k3s/server/node-token")
      
      # Get the pod IP of the master VM (inside the cluster)
      VM_IP=$(sshpass -p "apel1234" ssh -o StrictHostKeyChecking=no -p 30021 apel@$MASTER_NODE_IP "kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}'")
      
      # Log the values for debugging
      echo "Master Node IP: $MASTER_NODE_IP" > /home/apel/setup-log.txt
      echo "K3S Token: $K3S_TOKEN" >> /home/apel/setup-log.txt
      echo "VM IP: $VM_IP" >> /home/apel/setup-log.txt
      
      # Join as K3s agent
      curl -sfL https://get.k3s.io | K3S_URL=https://$VM_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -
  - path: /etc/systemd/system/k3s-agent-setup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Setup K3s Agent Node
      After=network.target
      Wants=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/k3s-agent-setup.sh
      RemainAfterExit=true
      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable k3s-agent-setup.service
  - systemctl start k3s-agent-setup.service
  - echo "K3s worker node setup initiated" > /home/apel/worker-setup-complete.txt
EOF
            }
          }
        }
      }
    }
  }
}

# Create a NodePort service for the agent if needed
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubernetes_service" "github_agent_nodeport_service" {
  metadata {
    name      = "github-agent-nodeport"
    namespace = "default"
  }

  spec {
    selector = {
      "kubevirt.io/domain" = "github-action-agent"
    }

    port {
      protocol    = "TCP"
      port        = 22
      target_port = 22
      node_port   = 30020
    }

    type = "NodePort"
  }
}

# Output to save the worker node details
resource "local_file" "worker_node_details" {
  depends_on = [kubevirt_virtual_machine.github-action-agent]
  filename   = "${path.module}/worker_node_details.tf"
  content    = <<-EOT
    # Worker node information
    # To be used by other Terraform configurations
    worker_node_name = "${kubevirt_virtual_machine.github-action-agent.metadata.name}"
    worker_node_namespace = "${kubevirt_virtual_machine.github-action-agent.metadata.namespace}"
  EOT
}

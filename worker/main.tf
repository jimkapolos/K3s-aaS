terraform {
  required_providers {
    kubevirt = {
      source  = "kubevirt/kubevirt"
      version = "0.0.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "kubevirt" {
  config_context = "kubernetes-admin@kubernetes"
}

provider "kubernetes" {
  config_context = "kubernetes-admin@kubernetes"
}

# Παίρνουμε την IP του master node
data "external" "k3s_master_ip" {
  program = ["bash", "-c", <<EOT
kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}' | jq -R '{ "output": . }'
EOT
  ]
}

output "k3s_master_ip" {
  description = "The IP of the K3s master node VM"
  value       = data.external.k3s_master_ip.result["output"]
}

# Δημιουργία του cloud-init user-data
locals {
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

packages:
  - curl
  - sshpass

write_files:
  - path: /usr/local/bin/k3s-agent-setup.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      echo "Starting K3s agent setup..."
      
      # Χρήση της IP από το terraform
      export K3S_MASTER_IP="${data.external.k3s_master_ip.result["output"]}"
      echo "K3s Master IP: $K3S_MASTER_IP"
      
      # Λήψη του token κατευθείαν από τον master
      echo "Retrieving K3s token from master node..."
      MAX_ATTEMPTS=10
      ATTEMPT=0
      
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        echo "Attempt $((ATTEMPT+1)) to retrieve token..."
        export K3S_TOKEN=$(sshpass -p "apel1234" ssh -o StrictHostKeyChecking=no apel@$K3S_MASTER_IP "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null)
        
        if [ -n "$K3S_TOKEN" ]; then
          echo "Token retrieved successfully!"
          break
        fi
        
        echo "Failed to retrieve token, waiting 30 seconds before retry..."
        sleep 30
        ATTEMPT=$((ATTEMPT+1))
      done
      
      if [ -z "$K3S_TOKEN" ]; then
        echo "Failed to retrieve K3s token after $MAX_ATTEMPTS attempts. Exiting."
        exit 1
      fi
      
      # Εγκατάσταση του K3s agent
      echo "Installing K3s agent..."
      curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -
      
      echo "K3s agent installation complete!"

  - path: /etc/systemd/system/k3s-agent-setup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Setup K3s Agent Node
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/k3s-agent-setup.sh
      RemainAfterExit=true

      [Install]
      WantedBy=multi-user.target

runcmd:
  - echo "Starting initial setup..." > /var/log/k3s-agent-setup.log
  - apt-get update
  - apt-get install -y curl sshpass
  - systemctl daemon-reload
  - systemctl enable k3s-agent-setup.service
  - systemctl start k3s-agent-setup.service
EOF
}

# Δημιουργία Kubernetes Secret με το cloud-init user-data
resource "kubernetes_secret" "cloud_init_secret" {
  metadata {
    name      = "github-action-agent-cloud-init"
    namespace = "default"
  }

  data = {
    "userdata" = base64encode(local.user_data)
  }
}

# Δημιουργία του agent VM με cloud-init από Secret
resource "kubevirt_virtual_machine" "github-action-agent" {
  depends_on = [kubernetes_secret.cloud_init_secret]
  
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
            cloud_init_no_cloud {
              user_data_secret_ref {
                name = kubernetes_secret.cloud_init_secret.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

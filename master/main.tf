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

  spec {
    run_strategy = "Always"

    data_volume_templates {
      metadata {
        name      = "ubuntu-disk4"
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
          "kubevirt.io/domain" = "github-action"
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
              name = "ubuntu-disk4"
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
  - path: /usr/local/bin/k3s-setup.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      echo "apel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
      sudo apt-get update
      sudo apt-get install -y bash-completion sshpass uidmap ufw
      echo "source <(kubectl completion bash)" >> ~/.bashrc
      echo "export KUBE_EDITOR=\"/usr/bin/nano\"" >> ~/.bashrc
      wget https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-full-1.7.6-linux-amd64.tar.gz
      sudo tar Cxzvvf /usr/local nerdctl-full-1.7.6-linux-amd64.tar.gz
      cd /usr/local/bin && containerd-rootless-setuptool.sh install
      sudo ufw disable
      curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="--cluster-cidr=20.10.0.0/16" sh
      

  - path: /etc/systemd/system/k3s-setup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Setup K3s Master Node
      After=network.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/k3s-setup.sh
      RemainAfterExit=true

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable k3s-setup.service
  - systemctl start k3s-setup.service
EOF
            }
          }
        }
      }
    }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubernetes_service" "github_nodeport_service" {
  metadata {
    name      = "github-nodeport"
    namespace = "default"
  }

  spec {
    selector = {
      "kubevirt.io/domain" = "github-action"
    }

    port {
      protocol    = "TCP"
      port        = 22
      target_port = 22
      node_port   = 30021
    }

    type = "NodePort"
  }
}



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

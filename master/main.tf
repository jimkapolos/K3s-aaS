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

# Προσθήκη outputs για την IP και το token
data "external" "master_ip" {
  program = ["bash", "-c", "sleep 180 && kubectl get vmi github-action -o jsonpath='{\"ip\":\"{.status.interfaces[0].ipAddress}\"}' || echo '{\"ip\":\"pending\"}'"]
  depends_on = [kubevirt_virtual_machine.github-action]
}

data "external" "k3s_token" {
  program = ["bash", "-c", "sleep 200 && ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 apel@$(kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}') 'sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null' | jq -R '{token: .}' || echo '{\"token\":\"pending\"}'"]
  depends_on = [data.external.master_ip]
}

output "master_ip" {
  value = data.external.master_ip.result.ip
  description = "The IP address of the K3s master node"
}

output "k3s_token" {
  value = data.external.k3s_token.result.token
  description = "The K3s token for agent nodes to join the cluster"
  sensitive = true
}

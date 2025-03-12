# master.tf
terraform {
  required_providers {
    kubevirt = {
      source  = "kubevirt/kubevirt"
      version = "0.0.1"
    }
  }

variable "namespace" {
  description = "The namespace to deploy resources"
  type        = string
  default     = "default"
}

provider "kubevirt" {
  config_context = "kubernetes-admin@kubernetes"
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubernetes_namespace" "namespace" {
  metadata {
    name = var.namespace
  }
}

resource "kubevirt_virtual_machine" "github-action-master" {
  metadata {
    name      = "github-action-master-${var.namespace}"
    namespace = var.namespace
    annotations = {
      "kubevirt.io/domain" = "github-action-master-${var.namespace}"
    }
  }

  spec {
    run_strategy = "Always"

    data_volume_templates {
      metadata {
        name      = "ubuntu-disk-master-${var.namespace}"
        namespace = var.namespace
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
          "kubevirt.io/domain" = "github-action-master-${var.namespace}"
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
              name = "ubuntu-disk-master-${var.namespace}"
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
      
      # Εξαγωγή των δεδομένων που χρειάζονται στους workers
      # Αποθήκευση IP, token και kubeconfig σε αρχεία
      IP_ADDRESS=$(hostname -I | awk '{print $1}')
      echo "$IP_ADDRESS" > /home/apel/master_ip.txt
      sudo cat /var/lib/rancher/k3s/server/node-token > /home/apel/k3s_token.txt
      sudo cp /etc/rancher/k3s/k3s.yaml /home/apel/k3s_config.yaml
      sudo sed -i "s/127.0.0.1/$IP_ADDRESS/g" /home/apel/k3s_config.yaml
      sudo chown apel:apel /home/apel/master_ip.txt /home/apel/k3s_token.txt /home/apel/k3s_config.yaml
      sudo chmod 644 /home/apel/master_ip.txt /home/apel/k3s_token.txt /home/apel/k3s_config.yaml

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

resource "kubernetes_service" "github_nodeport_service" {
  metadata {
    name      = "github-master-${var.namespace}-nodeport"
    namespace = var.namespace
  }

  spec {
    selector = {
      "kubevirt.io/domain" = "github-action-master-${var.namespace}"
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

# Εξάγουμε την IP του master VM
data "kubernetes_resource" "github_master_vm_ip" {
  depends_on = [kubevirt_virtual_machine.github-action-master]
  
  api_version = "kubevirt.io/v1"
  kind        = "VirtualMachineInstance"
  
  metadata {
    name      = "github-action-master-${var.namespace}"
    namespace = var.namespace
  }

  timeouts {
    read = "10m"
  }
}

# Εξάγουμε το namespace, master_ip, και nodeport ως outputs
output "namespace" {
  value = var.namespace
  description = "The namespace used for deployment"
}

output "master_ip" {
  value = jsondecode(data.kubernetes_resource.github_master_vm_ip.manifest).status.interfaces[0].ipAddress
  description = "The IP address of the master node"
}

output "master_nodeport" {
  value = kubernetes_service.github_nodeport_service.spec[0].port[0].node_port
  description = "The NodePort for SSH access to the master"
}

# Προαιρετικά: Γράφουμε τα outputs σε ένα τοπικό αρχείο για εύκολη πρόσβαση
resource "local_file" "k3s_info" {
  content = jsonencode({
    namespace = var.namespace
    master_ip = jsondecode(data.kubernetes_resource.github_master_vm_ip.manifest).status.interfaces[0].ipAddress
    master_nodeport = kubernetes_service.github_nodeport_service.spec[0].port[0].node_port
  })
  filename = "${path.module}/k3s_info.json"
}

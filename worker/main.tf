terraform {
  required_providers {
    kubevirt = {
      source  = "kubevirt/kubevirt"
      version = "0.0.1"
    }
  }
}

variable "namespace" {
  description = "The namespace to deploy resources"
  type        = string
  default     = "default"
}

variable "master_ip" {
  description = "The IP address of the K3s master node"
  type        = string
  default     = "default"
}

variable "k3s_token" {
  description = "The token of the K3s master node"
  type        = string
  default     = "default"
}

variable "namespace_master" {
  description = "The namespace from master"
  type        = string
  default     = "default"
}


provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kubernetes-admin@kubernetes"
}

provider "kubevirt" {
  config_context = "kubernetes-admin@kubernetes"
}

resource "kubernetes_namespace" "namespace" {
  metadata {
    name = var.namespace_master
  }
}



resource "kubevirt_virtual_machine" "github-action-agent" {
  metadata {
    name      = "github-action-agent-${var.namespace}"
    namespace = var.namespace_master
    annotations = {
      "kubevirt.io/domain" = "github-action-agent-${var.namespace}"
    }
  }

  spec {
    run_strategy = "Always"

    data_volume_templates {
      metadata {
        name      = "ubuntu-disk-worker-${var.namespace}"
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
          "kubevirt.io/domain" = "github-action-agent-${var.namespace}"
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
              name = "ubuntu-disk-worker-${var.namespace}"
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
      export VM_IP=${var.master_ip}
      export K3S_TOKEN=${var.k3s_token}
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
EOF
            }
          }
        }
      }
    }
  }
}


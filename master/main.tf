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

provider "kubevirt" {
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
    running = true

    template {
      metadata {
        labels = {
          "kubevirt.io/domain" = "github-action-master-${var.namespace}"
        }
      }

      spec {
        domain {
          cpu {
            cores = 2
          }
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
              memory = "2Gi"
            }
          }
        }

        volumes {
          name = "rootdisk"
          volume_source {
            data_volume {
              name = "ubuntu-disk-master-${var.namespace}"
            }
          }
        }

        volumes {
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
EOF
            }
          }
        }

        networks {
          name = "default"
          network_source {
            pod {}
          }
        }

        interfaces {
          name                     = "default"
          interface_binding_method = "InterfaceMasquerade"
        }
      }
    }
  }

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

      networks {
        name = "default"
        network_source {
          pod {}
        }
      }

      volumes {
        name = "rootdisk"
        volume_source {
          data_volume {
            name = "ubuntu-disk-master-${var.namespace}"
          }
        }
      }

      volumes {
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
EOF
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
    }

    type = "NodePort"
  }
}

data "external" "k3s_master_ip" {
  depends_on = [kubevirt_virtual_machine.github-action-master]

  program = ["bash", "-c", <<EOT
while true; do
  IP=$(kubectl get vmi -n ${var.namespace} github-action-master-${var.namespace} -o jsonpath='{.status.interfaces[0].ipAddress}')
  if [ -n "$IP" ]; then
    echo "{ \"output\": \"$IP\" }"
    exit 0
  fi
  echo "Waiting for VM to get an IP..."
  sleep 10
done
EOT
  ]
}

output "k3s_master_ip" {
  value = data.external.k3s_master_ip.result["output"]
}

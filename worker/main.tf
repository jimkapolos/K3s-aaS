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

# Παίρνουμε την IP του master node
data "external" "k3s_master_ip" {
  program = ["bash", "-c", <<EOT
kubectl get vmi github-action -o jsonpath='{.status.interfaces[0].ipAddress}' | jq -R '{ "output": . }'
EOT
  ]
}

# Δημιουργία αρχείου SSH config για να παρακάμψουμε το StrictHostKeyChecking
resource "local_file" "ssh_config" {
  content  = <<-EOT
    Host k3s-master
      HostName ${data.external.k3s_master_ip.result["output"]}
      User apel
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
  EOT
  filename = "${path.module}/ssh_config"
}

# Δημιουργία script που θα λάβει το token χωρίς να χρειάζεται sshpass
resource "local_file" "get_token_script" {
  content  = <<-EOT
    #!/bin/bash
    # Δημιουργία προσωρινού αρχείου password
    echo 'apel1234' > ${path.module}/temp_pass
    chmod 600 ${path.module}/temp_pass
    
    # Χρήση του SSH με αρχείο password αντί για sshpass
    ssh -F ${path.module}/ssh_config -o PasswordAuthentication=yes k3s-master 'sudo cat /var/lib/rancher/k3s/server/node-token' > ${path.module}/node-token
    
    # Καθαρισμός του αρχείου password
    rm ${path.module}/temp_pass
  EOT
  filename = "${path.module}/get_token.sh"

  provisioner "local-exec" {
    command = "chmod +x ${path.module}/get_token.sh"
  }
}

# Εκτέλεση του script για να λάβει το token
resource "null_resource" "get_k3s_token" {
  depends_on = [local_file.get_token_script, local_file.ssh_config]
  
  provisioner "local-exec" {
    command = "${path.module}/get_token.sh"
  }
}

# Διαβάζουμε το token που αποθηκεύσαμε στο τοπικό αρχείο
data "local_file" "k3s_token" {
  depends_on = [null_resource.get_k3s_token]
  filename   = "${path.module}/node-token"
}

# Εναλλακτική προσέγγιση: Δημιουργία K3s agent setup script με hardcoded τιμές
resource "local_file" "k3s_agent_setup" {
  depends_on = [data.external.k3s_master_ip, data.local_file.k3s_token]
  
  content  = <<-EOT
#!/bin/bash
echo "apel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
sudo apt-get update
sudo apt-get install -y curl

# Τιμές από το Terraform
export K3S_MASTER_IP="${data.external.k3s_master_ip.result["output"]}"
export K3S_TOKEN="${data.local_file.k3s_token.content}"

echo "Using K3s Master IP: $K3S_MASTER_IP"
echo "K3s Token is configured"

curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -
EOT
  filename = "${path.module}/k3s_agent_setup.sh"
}

output "k3s_master_ip" {
  description = "The IP of the K3s master node VM"
  value       = data.external.k3s_master_ip.result["output"]
}

output "k3s_token" {
  description = "The token for joining worker nodes"
  value       = data.local_file.k3s_token.content
  sensitive   = true
}

# Δημιουργία του agent VM με δυναμικό cloud-init 
resource "kubevirt_virtual_machine" "github-action-agent" {
  depends_on = [local_file.k3s_agent_setup]
  
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
      sudo apt-get install -y curl
      
      # Τιμές από το Terraform - περνιούνται απευθείας στο cloud-init
      export K3S_MASTER_IP="${data.external.k3s_master_ip.result["output"]}"
      export K3S_TOKEN="${data.local_file.k3s_token.content}"
      
      echo "Using K3s Master IP: $K3S_MASTER_IP"
      echo "K3s Token is configured"
      
      curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN sh -

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

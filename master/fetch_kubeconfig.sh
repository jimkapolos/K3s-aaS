#!/bin/bash
set -e

MASTER_IP=$1

# Αντιγραφή του kubeconfig αρχείου
sshpass -p "apel1234" scp -o StrictHostKeyChecking=no apel@$MASTER_IP:/etc/rancher/k3s/k3s.yaml ./k3s.yaml

# Επιστροφή JSON για το Terraform
echo "{ \"output\": \"$(pwd)/k3s.yaml\" }"

#!/bin/bash

MIN_PORT=30000
MAX_PORT=32767

#  Find all reserved ports from Kubernetes
USED_PORTS=$(kubectl get services --all-namespaces -o=jsonpath='{.items[*].spec.ports[*].nodePort}')

# Find the first available port
for ((port=MIN_PORT; port<=MAX_PORT; port++)); do
    if [[ ! " ${USED_PORTS[@]} " =~ " $port " ]]; then
        echo "{\"output\": \"$port\"}"
        exit 0
    fi
done

# Αν δεν βρεθεί διαθέσιμη θύρα
echo "Error: No free NodePort found!" >&2
exit 1

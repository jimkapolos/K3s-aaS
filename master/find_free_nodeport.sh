#!/bin/bash

# Εύρος θυρών NodePort (σύμφωνα με Kubernetes)
MIN_PORT=30000
MAX_PORT=32767

# Βρες μια διαθέσιμη θύρα
for ((port=MIN_PORT; port<=MAX_PORT; port++)); do
    if ! ss -tuln | grep -q ":$port "; then
        echo "{\"output\": \"$port\"}"
        exit 0
    fi
done

# Αν δεν βρεθεί διαθέσιμη θύρα
echo "Error: No free NodePort found!" >&2
exit 1

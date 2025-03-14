#!/bin/bash

start_port=30020
end_port=32767

for port in $(seq $start_port $end_port); do
    if ! netstat -tuln | grep -q ":$port "; then
        echo "{\"output\": \"$port\"}"
        exit 0
    fi
done

echo "{\"error\": \"No free ports available\"}" >&2
exit 1

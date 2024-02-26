#!/bin/bash

set -euo pipefail

echo "shutdown" > "$PIPE_FILE"

# wait for the service to shutdown
while true; do
  if [[ ! -p "$PIPE_FILE" ]] && [[ ! -f "$PID_FILE" ]]; then
    break
  fi
  sleep 1
done

exit 0

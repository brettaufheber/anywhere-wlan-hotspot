#!/bin/bash

set -euo pipefail

if [[ ! -p "$PIPE_FILE" ]]; then
  rm -f "$PIPE_FILE"
fi

# start service
"$APP_FILE" &

# wait for pipe file and service application
while true; do
  if [[ -p "$PIPE_FILE" ]] && [[ -f "$PID_FILE" ]]; then
    break
  fi
  sleep 1
done

echo "connect" > "$PIPE_FILE"

exit 0

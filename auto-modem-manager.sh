#!/bin/bash

function main {

  ## external variables
  # PIPE_FILE
  # LOCK_FILE
  # PID_FILE
  # VENDOR_ID
  # PRODUCT_ID
  # MODE_SWITCH_OPTIONS
  #

  local RUNNING
  local CONNECT_DELAY
  local LINE
  local CMD

  RUNNING=true
  ALLOW_ROAMING=no
  IP_TYPE=ipv4
  CONNECT_DELAY=0

  # create PID file
  echo "$$" > "$PID_FILE"

  # create pipe
  mkfifo "$PIPE_FILE"
  chmod 622 "$PIPE_FILE"

  # create lock file
  echo "DISCONNECTED" > "$LOCK_FILE"

  # processes incoming data
  while $RUNNING; do
    if read -r LINE; then

      # separate the command and possible arguments
      IFS=' ' read -ra CMD <<< "$LINE"

      case "${CMD[0]}" in
        connect)
          if [[ "${#CMD[@]}" -ne 1 ]]; then
            echo "User-Input-Error:  The 'connect' command does not take any arguments" >&2
          elif [[ "$(cat "$LOCK_FILE")" != "DISCONNECTED" ]]; then
            echo "Invalid-State-Error: The 'connect' command is ignored because a connection is already active or being established" >&2
          else
            echo "Starting modem connection with a delay of $CONNECT_DELAY seconds..."
            echo "CONNECTING" > "$LOCK_FILE"
            (sleep "$CONNECT_DELAY" && connect_modem && echo "CONNECTED" > "$LOCK_FILE" || echo "DISCONNECTED" > "$LOCK_FILE") &
          fi
          ;;
        disconnect)
          if [[ "${#CMD[@]}" -ne 1 ]]; then
            echo "User-Input-Error:  The 'disconnect' command does not take any arguments" >&2
          elif [[ "$(cat "$LOCK_FILE")" != "CONNECTED" ]]; then
            echo "Invalid-State-Error: The 'disconnect' command is ignored because no active connection exists" >&2
          else
            echo "Stopping modem connection..."
            echo "DISCONNECTING" > "$LOCK_FILE"
            (disconnect_modem || true ; echo "DISCONNECTED" > "$LOCK_FILE") &
          fi
          ;;
        shutdown)
          if [[ "${#CMD[@]}" -ne 1 ]]; then
            echo "User-Input-Error:  The 'shutdown' command does not take any arguments" >&2
          elif [[ "$(cat "$LOCK_FILE")" == "CONNECTED" ]]; then
            echo "Stopping modem service and modem connection gracefully..."
            disconnect_modem || true
            echo "DISCONNECTED" > "$LOCK_FILE"
            RUNNING=false
          else
            echo "Stopping modem service gracefully..."
            RUNNING=false
          fi
          ;;
        set)
          if [[ "${#CMD[@]}" -ne 3 ]]; then
            echo "User-Input-Error:  The 'set <key> <value>' command requires exactly two argument" >&2
          else
            if [[ "${CMD[1]}" = 'connect-delay' && "${CMD[2]}" =~ ^[0-9]+$ ]]; then
              CONNECT_DELAY="${CMD[2]}"
              echo "Set connect delay to $CONNECT_DELAY seconds"
            elif [[ "${CMD[1]}" = 'allow-roaming' && "${CMD[2]}" =~ ^(true)|(yes)|(on)|(1)$ ]]; then
              ALLOW_ROAMING=yes
              echo "Allow roaming after reconnect"
            elif [[ "${CMD[1]}" = 'allow-roaming' && "${CMD[2]}" =~ ^(false)|(no)|(off)|(0)$ ]]; then
              ALLOW_ROAMING=no
              echo "Disallow roaming after reconnect"
            elif [[ "${CMD[1]}" = 'ip-type' && "${CMD[2]}" =~ ^(ipv4)|(ipv6)|(ipv4v6)$ ]]; then
              IP_TYPE="${CMD[2]}"
              echo "Set IP type to $IP_TYPE"
            else
              echo "User-Input-Error: Incorrect arguments for the 'set <key> <value>' command" >&2
            fi
          fi
          ;;
        *)
          echo "User-Input-Error: Unknown command: $LINE" >&2
          ;;
      esac
    else
      # ignore EOF mark
      sleep 1
    fi
  done < "$PIPE_FILE"

  wait

  rm -f "$PIPE_FILE"
  rm -f "$LOCK_FILE"
  rm -f "$PID_FILE"

  echo "The modem service has been shutdown"
}

function shutdown {

  echo "shutdown" > "$PIPE_FILE"
}

function shutdown_with_error {

  disconnect_modem || true

  rm -f "$PIPE_FILE"
  rm -f "$LOCK_FILE"
  rm -f "$PID_FILE"

  echo "The script stopped caused by unexpected return code $1 at line $2" >&2
  exit 2
}

function connect_modem {

  local LSUSB_OUTPUT
  local LSUSB_OUTPUT_EXIT_CODE
  local FIND_MODEM_OUTPUT
  local FIND_MODEM_OUTPUT_EXIT_CODE
  local BUS_NUM
  local DEV_NUM
  local USB_CLASS
  local MODEM_INDEX
  local MODEM_BEARER_INDEX
  local MODEM_DEVICE
  local APN

  set +e
  LSUSB_OUTPUT="$(lsusb | grep -E "ID\s+$VENDOR_ID:$PRODUCT_ID")"
  LSUSB_OUTPUT_EXIT_CODE="$?"
  set -e

  # start only if device could be found
  if [[ "$LSUSB_OUTPUT_EXIT_CODE" -ne 0 ]]; then
    echo "Could not find USB device $VENDOR_ID:$PRODUCT_ID" >&2
    return 1
  fi

  # load the usb serial driver with the specified vendor and product IDs
  modprobe usbserial "vendor=0x$VENDOR_ID" "product=0x$PRODUCT_ID"

  BUS_NUM=$(echo "$LSUSB_OUTPUT" | cut -d ' ' -f 2)
  DEV_NUM=$(echo "$LSUSB_OUTPUT" | cut -d ' ' -f 4 | tr -d ':')

  USB_CLASS="$(udevadm info --query=all --name="/dev/bus/usb/$BUS_NUM/$DEV_NUM" | grep -F 'ID_USB_INTERFACES=')"

  if [[ "$USB_CLASS" == *":08"* ]]; then
    echo "Perform USB mode switch..."
    if ! run_usb_modeswitch; then
      echo "Cannot connect to device $VENDOR_ID:$PRODUCT_ID because the mode switch failed" >&2
      return 1
    fi
  elif [[ "$USB_CLASS" == *":02"* || "$USB_CLASS" == *":0a"* ]]; then
    echo "Skip mode switch for $VENDOR_ID:$PRODUCT_ID because it is not necessary"
  else
    echo "Skip mode switch for $VENDOR_ID:$PRODUCT_ID because of an unexpected USB class" >&2
  fi

  if ! wait_modem_ready; then
    echo "Cannot connect to device $VENDOR_ID:$PRODUCT_ID because the modem failed the readiness check" >&2
    return 1
  fi

  # find the index and the primary serial port of the selected modem
  set +e
  FIND_MODEM_OUTPUT="$(find_modem)"
  FIND_MODEM_OUTPUT_EXIT_CODE="$?"
  set -e

  if [[ "$FIND_MODEM_OUTPUT_EXIT_CODE" -ne 0 ]]; then
    echo "Failed to find the modem matching $VENDOR_ID:$PRODUCT_ID" >&2
    return 1
  fi

  # extract index and the primary serial port
  MODEM_INDEX="$(echo "$FIND_MODEM_OUTPUT" | grep -oP 'index=\K\w+')"
  MODEM_DEVICE="$(echo "$FIND_MODEM_OUTPUT" | grep -oP 'device=\K/dev/\w+')"

  # enable modem
  echo "Enable modem (index=$MODEM_INDEX)"
  mmcli -m "$MODEM_INDEX" --enable

  # find APN using SIM card
  APN="$(get_apn "$MODEM_DEVICE")"

  # connect to the modem using the extracted parameters
  echo "Connecting to modem (apn=$APN, allow-roaming=$ALLOW_ROAMING, ip-type=$IP_TYPE)"
  mmcli -m "$MODEM_INDEX" --simple-connect="apn=$APN,allow-roaming=$ALLOW_ROAMING,ip-type=$IP_TYPE"

  setup_ppp_interface "$MODEM_DEVICE"
  set_default_interface

  # display current routing table
  echo "The current routing table:"
  ip route

  MODEM_BEARER_INDEX="$(mmcli -m "$MODEM_INDEX" --output-keyvalue | grep -F 'modem.generic.bearers.value' | grep -oP ':\s*/org/freedesktop/ModemManager\d+/Bearer/\K\d+' | head -n 1)"

  # show metrics about modem
  echo "The metrics about the established connection:"
  set +e
  mmcli -m "$MODEM_INDEX"
  mmcli -m "$MODEM_INDEX" -b "$MODEM_BEARER_INDEX"
  set -e
}

function disconnect_modem  {

  local FIND_MODEM_OUTPUT
  local FIND_MODEM_OUTPUT_EXIT_CODE
  local MODEM_INDEX
  local MODEM_DEVICE

  # find the index and the primary serial port of the selected modem
  set +e
  FIND_MODEM_OUTPUT="$(find_modem)"
  FIND_MODEM_OUTPUT_EXIT_CODE="$?"
  set -e

  if [[ "$FIND_MODEM_OUTPUT_EXIT_CODE" -ne 0 ]]; then
    echo "Failed to find the modem matching $VENDOR_ID:$PRODUCT_ID" >&2
    return 1
  fi

  # extract index and the primary serial port
  MODEM_INDEX="$(echo "$FIND_MODEM_OUTPUT" | grep -oP 'index=\K\w+')"
  MODEM_DEVICE="$(echo "$FIND_MODEM_OUTPUT" | grep -oP 'device=\K/dev/\w+')"

# TODO: interface dynamisch ermitteln, eventuell ausgabe von pppd und mmcli prüfen
  ip route del default
  ip link set ppp0 down

  set +e
  echo "Disconnecting modem with index $MODEM_INDEX..."
  mmcli -m "$MODEM_INDEX" --simple-disconnect \
    && echo "Modem disconnected."
  set -e

  set +e
  echo "Disabling modem with index $MODEM_INDEX..."
  mmcli -m "$MODEM_INDEX" --disable \
    && echo "Modem disabled."
  set -e

  # teardown PPP interface
  echo "Sending SIGTERM to pppd process for device $MODEM_DEVICE..."
  pkill -f "pppd $MODEM_DEVICE"
  echo "SIGTERM sent to pppd process."

  while pgrep -f "pppd $MODEM_DEVICE" > /dev/null; do
      echo "Waiting for the pppd process to terminate. Recheck in 5 seconds..."
      sleep 5
  done
}

function run_usb_modeswitch {

  local OUTPUT            # output of the usb_modeswitch operation
  local OUTPUT_EXIT_CODE  # exit code of the usb_modeswitch operation
  local RETRY_LIMIT       # maximum number of retry attempts
  local RETRY_COUNT       # current number of retry attempts

  RETRY_LIMIT=10
  RETRY_COUNT=0

  while true; do

    set +e
    # shellcheck disable=SC2086
    OUTPUT="$(usb_modeswitch -v "0x$VENDOR_ID" -p "0x$PRODUCT_ID" $MODE_SWITCH_OPTIONS 2>&1)"
    OUTPUT_EXIT_CODE=$?
    set -e

    if [[ $OUTPUT_EXIT_CODE -ne 0 ]] || echo "$OUTPUT" | grep -q "No devices in default mode found"; then
      ((RETRY_COUNT++))
      if [[ $RETRY_COUNT -ge $RETRY_LIMIT ]]; then
        echo "Aborting the mode switch operation because the maximum retry limit has been reached" >&2
        return 1
      fi
      echo "The mode switch failed or device not found in default mode. Retrying in 5 seconds..."
      sleep 5
    else
      echo "$OUTPUT"
      echo "The mode switch executed successfully"
      break
    fi
  done
}

function wait_modem_ready {

  local RETRY_LIMIT # maximum number of retry attempts
  local RETRY_COUNT # current number of retry attempts

  RETRY_LIMIT=20
  RETRY_COUNT=0

  while true; do
    if mmcli -L | grep -qE '^\s*/org/freedesktop/ModemManager[0-9]*/Modem/[0-9]+\s+'; then
      break
    else
      ((RETRY_COUNT++))
      if [[ $RETRY_COUNT -ge $RETRY_LIMIT ]]; then
        echo "Aborting the readiness wait operation because the maximum retry limit has been reached" >&2
        return 1
      fi
      echo "The modem is not ready. Retrying in 5 seconds..."
      sleep 5
    fi
  done
}

function get_apn {

  local TEMP_OUTPUT_FILE  # temporary file for modem output
  local MODEM_DEVICE      # the device file of the modem
  local CAT_PID           # process ID for the 'cat' command
  local CGDCONT_OUTPUT    # output of the "AT+CGDCONT?" command
  local APN               # Access Point Name from the CGDCONT response

  # create a temporary file for modem output
  TEMP_OUTPUT_FILE="$(mktemp)"
  MODEM_DEVICE="$1"

  # start the 'cat' command in the background to read modem outputs
  cat "$MODEM_DEVICE" > "$TEMP_OUTPUT_FILE" &
  CAT_PID=$!

  sleep 1

  # send the "AT+CGDCONT?" command to the modem
  echo -e 'AT+CGDCONT?\r' > "$MODEM_DEVICE"

  # wait for a response from the modem that contains "+CGDCONT:"
  while true; do
    sleep 1
    if grep -q "+CGDCONT:" "$TEMP_OUTPUT_FILE"; then
      break
    fi
  done

  # retrieve the CGDCONT response
  CGDCONT_OUTPUT=$(grep "+CGDCONT:" "$TEMP_OUTPUT_FILE")

  # terminate the 'cat' process and delete the temporary file
  kill $CAT_PID
  rm "$TEMP_OUTPUT_FILE"

  # extract the APN from the CGDCONT response
  echo "$CGDCONT_OUTPUT" | cut -d',' -f3 | tr -d '"'
}

function setup_ppp_interface {

  local TEMP_PPP_CONFIG_FILE
  local MODEM_DEVICE

  # create a temporary file for PPP configuration
  TEMP_PPP_CONFIG_FILE="$(mktemp)"
  MODEM_DEVICE="$1"

  echo '
  noauth
  usepeerdns
  defaultroute
  replacedefaultroute
  persist
  ' > "$TEMP_PPP_CONFIG_FILE"

  # setup PPP interface
  pppd "$MODEM_DEVICE" file "$TEMP_PPP_CONFIG_FILE"

  # make sure pppd has enough time to read the temporary file
  sleep 3

  rm "$TEMP_PPP_CONFIG_FILE"
}

function set_default_interface {

  local INTERFACE_NOT_READY

  ip route del default

  # set modem as default interface
  INTERFACE_NOT_READY=true
  while "$INTERFACE_NOT_READY"; do
    sleep 1
    if ip route add default dev ppp0; then
      INTERFACE_NOT_READY=false
    fi
  done
}

function find_modem {

  local MODEM_INDEX
  local MODEM_DEVICE
  local UDEVADM_OUTPUT
  local VENDOR_ID_FOUND
  local PRODUCT_ID_FOUND

  for MODEM_INDEX in $(mmcli -L | grep -oP '^\s*/org/freedesktop/ModemManager\d+/Modem/\K\d+'); do

    # find the primary serial port
    MODEM_DEVICE="/dev/$(mmcli -m "$MODEM_INDEX" --output-keyvalue | grep -F 'modem.generic.ports.value' | grep -oP 'ttyUSB\d+' | head -n 1)"

    if [[ -z "$MODEM_DEVICE" ]]; then
      echo "No primary serial port found for modem index $MODEM_INDEX" >&2
      continue
    fi

    UDEVADM_OUTPUT="$(udevadm info --query=property --name="$MODEM_DEVICE")"
    VENDOR_ID_FOUND=$(echo "$UDEVADM_OUTPUT" | grep -F 'ID_VENDOR_ID=' | cut -d '=' -f 2)
    PRODUCT_ID_FOUND=$(echo "$UDEVADM_OUTPUT" | grep -F 'ID_MODEL_ID=' | cut -d '=' -f 2)

    if [[ "$VENDOR_ID_FOUND" == "$VENDOR_ID" && "$PRODUCT_ID_FOUND" == "$PRODUCT_ID" ]]; then
      echo "Found matching modem: index=$MODEM_INDEX, device=$MODEM_DEVICE"
      return 0
    fi
  done

  echo "No matching modem found" >&2
  return 1
}

set -euEo pipefail
trap 'RC=$?; shutdown_with_error "$RC" "$LINENO"' ERR
trap 'shutdown' SIGINT SIGTERM
main "$@"
exit 0

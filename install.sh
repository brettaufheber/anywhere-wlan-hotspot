#!/bin/bash

set -euo pipefail

# make sure to run this script as a privileged user
if [[ $EUID -ne 0 ]]; then
  echo "Error: require root privileges" >&2
  exit 1
fi

USB_DEVICE_ID="$1"              # use lsusb to find the USB ID for your device (e.g. 12d1:1003)
MODE_SWITCH_OPTIONS="${2:--K}"  # additional options for the usb_modeswitch call (-K, -X, ...)
ALLOW_ROAMING="${3:-no}"        # roaming flag (yes or no)

VENDOR_ID="$(echo "$USB_DEVICE_ID" | cut -d':' -f1)"
PRODUCT_ID="$(echo "$USB_DEVICE_ID" | cut -d':' -f2)"

SERVICE_NAME="AutoModemManager.service"
INSTALL_DIR="/opt/auto-modem-manager"
PIPE_FILE="/var/run/auto-modem-manager-control-pipe"
LOCK_FILE="/var/run/auto-modem-manager.lock"
PID_FILE="/run/auto-modem-manager.pid"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
ENV_FILE="$INSTALL_DIR/config.env"
PIPE_CMD_HELPER_FILE="/usr/local/sbin/auto-modem-manager-send.sh"
UDEV_RULE_FILE="/etc/udev/rules.d/70-auto-modem-manager.rules"

echo "installing modem service..."

# stop the service if necessary
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "The modem service is currently active. Stopping it before proceeding with installation..."
  systemctl stop "$SERVICE_NAME"
fi

mkdir -p "$INSTALL_DIR/sbin/"

cp -fp ./auto-modem-manager.sh "$INSTALL_DIR/sbin/"
cp -fp ./auto-modem-manager-setup.sh "$INSTALL_DIR/sbin/"
cp -fp ./auto-modem-manager-shutdown.sh "$INSTALL_DIR/sbin/"

{
  echo "#!/bin/bash"
  echo
  echo "set -euo pipefail"
  echo
  echo "source '$ENV_FILE'"
  echo
  echo "for ARG in \"\$@\"; do"
  echo "  echo \"\$ARG\" > \"\$PIPE_FILE\""
  echo "done"
  echo
  echo "exit 0"
} > "$PIPE_CMD_HELPER_FILE"

{
  echo "[Unit]"
  echo "Description=USB WWAN modem and internet connection"
  echo "After=network.target local-fs.target"
  echo
  echo "[Service]"
  echo "Type=forking"
  echo "EnvironmentFile=$ENV_FILE"
  echo "PIDFile=$PID_FILE"
  echo "ExecStart=$INSTALL_DIR/sbin/auto-modem-manager-setup.sh"
  echo "ExecStop=$INSTALL_DIR/sbin/auto-modem-manager-shutdown.sh"
  echo "TimeoutStartSec=10s"
  echo "TimeoutStopSec=30s"
  echo
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > "$SERVICE_FILE"

{
  echo "PIPE_FILE=\"$PIPE_FILE\""
  echo "LOCK_FILE=\"$LOCK_FILE\""
  echo "PID_FILE=\"$PID_FILE\""
  echo "APP_FILE=\"$INSTALL_DIR/sbin/auto-modem-manager.sh\""
  echo "VENDOR_ID=\"$VENDOR_ID\""
  echo "PRODUCT_ID=\"$PRODUCT_ID\""
  echo "MODE_SWITCH_OPTIONS=\"$MODE_SWITCH_OPTIONS\""
  echo "ALLOW_ROAMING=\"$ALLOW_ROAMING\""
} > "$ENV_FILE"

chmod +x "$PIPE_CMD_HELPER_FILE"

# inform systemd about the new or modified service file
systemctl daemon-reload

# make changes active
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "modem service has been installed"
echo "adding udev rule..."

# create the udev rule using the provided IDs
{
  echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"$VENDOR_ID\", ATTRS{idProduct}==\"$PRODUCT_ID\", RUN+=\"$PIPE_CMD_HELPER_FILE connect\""
  echo "ACTION==\"remove\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"$VENDOR_ID\", ATTRS{idProduct}==\"$PRODUCT_ID\", RUN+=\"$PIPE_CMD_HELPER_FILE disconnect\""
} > "$UDEV_RULE_FILE"

# set correct permissions for the udev rule file
chmod 644 "$UDEV_RULE_FILE"

# make changes active
udevadm control --reload-rules
udevadm trigger

echo "udev rule for USB modem with Vendor ID $VENDOR_ID and Product ID $PRODUCT_ID has been created."

exit 0

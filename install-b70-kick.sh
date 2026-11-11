#!/usr/bin/env bash
# Installs the B70 telemetry workaround as a root systemd service.
set -e
cd "$(dirname "$0")"
sudo install -m 755 b70-telemetry-kick.sh /usr/local/sbin/
sudo install -m 644 b70-telemetry-kick.service /etc/systemd/system/
sudo restorecon /usr/local/sbin/b70-telemetry-kick.sh /etc/systemd/system/b70-telemetry-kick.service
sudo systemctl daemon-reload
sudo systemctl enable b70-telemetry-kick.service
sudo systemctl restart b70-telemetry-kick.service
systemctl is-active b70-telemetry-kick.service

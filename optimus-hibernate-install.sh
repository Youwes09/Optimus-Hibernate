#!/bin/bash
# Install Arch Optimus Hibernate script and service

SCRIPT_PATH="/usr/local/bin/arch-optimus-hibernate.sh"
SERVICE_PATH="/etc/systemd/system/arch-hibernate.service"

sudo cp arch-optimus-hibernate.sh "$SCRIPT_PATH"
sudo chmod +x "$SCRIPT_PATH"
sudo cp arch-hibernate.service "$SERVICE_PATH"
sudo systemctl daemon-reload
sudo systemctl enable arch-hibernate
sudo systemctl start arch-hibernate

echo "Arch Optimus Hibernate script installed and running."

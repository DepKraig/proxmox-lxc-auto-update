#!/usr/bin/env bash
# Run this once on the Proxmox host to set up email relay via Gmail/msmtp.
set -e

apt update
apt install -y msmtp msmtp-mta mailutils

echo "Packages installed. Now edit /etc/msmtprc with your Gmail App Password."
echo "(the msmtprc file is provided separately - copy it into place, then edit the password line)"

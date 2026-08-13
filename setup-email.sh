#!/usr/bin/env bash
# Run this once on the Proxmox host to set up email relay via Gmail/msmtp.
set -e

apt update
apt install -y msmtp msmtp-mta mailutils

# Pre-create the msmtp log file. If left for msmtp/sendmail to create on
# first run, it can end up with permissions that cause a (harmless but
# noisy) "cannot log to /var/log/msmtp.log: Permission denied" warning
# even when the email itself sends successfully.
touch /var/log/msmtp.log
chown root:root /var/log/msmtp.log
chmod 644 /var/log/msmtp.log

echo "Packages installed. Now edit /etc/msmtprc with your Gmail App Password."
echo "(the msmtprc file is provided separately - copy it into place, then edit the password line)"

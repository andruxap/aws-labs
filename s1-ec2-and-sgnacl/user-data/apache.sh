#!/bin/bash
# Part B — minimal Apache so each instance has something to curl.
# The course uses `yum`; AL2023 uses `dnf` (yum is a symlink, but be explicit).
dnf install -y httpd
systemctl start httpd
systemctl enable httpd

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "<h1>S1 Part B</h1><p>instance: $IID</p>" > /var/www/html/index.html
systemctl restart httpd

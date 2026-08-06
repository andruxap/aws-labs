#!/bin/bash
# One User Data script for both instances. COLOR and BUCKET are substituted by
# deploy.sh before launch — the course ships two near-identical files instead.
#
# The instance pulls its page from S3 using its instance profile, so the code
# lives in one place and the servers are disposable.
COLOR="__COLOR__"
BUCKET="__BUCKET__"

dnf install -y httpd
systemctl start httpd
systemctl enable httpd

mkdir -p "/var/www/html/$COLOR"
aws s3 cp "s3://$BUCKET/$COLOR/" "/var/www/html/$COLOR/" --recursive

# The ALB health check targets /$COLOR/index.html. A bare / returning 403 is
# fine and expected — nothing is ever routed there.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Stamp which instance actually answered — this is how you see routing work.
sed -i "s|</div>|<p style=\"opacity:.65;font-size:.8rem\">$IID &middot; $AZ</p></div>|" \
  "/var/www/html/$COLOR/index.html"

systemctl restart httpd

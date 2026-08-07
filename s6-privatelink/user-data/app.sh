#!/bin/bash
# Shared Services internal app. Runs on a PRIVATE subnet instance with no public
# IP and no route to the internet — it is reachable only through the NLB and the
# endpoint service in front of it.
dnf install -y httpd
systemctl start httpd
systemctl enable httpd

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(meta instance-id)
PRIV=$(meta local-ipv4)
# Absent for an instance with no public IP — proving that is part of the point.
PUB=$(meta public-ipv4 2>/dev/null || echo "NONE")
[ -z "$PUB" ] && PUB="NONE"

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<title>Shared Services</title></head><body>
<h1>__NAME__</h1>
<p>instance: $IID</p>
<p>private ip: $PRIV</p>
<p>public ip: $PUB</p>
</body></html>
EOF

# Machine-readable, for the validation script.
echo "__NAME__ $IID $PRIV public=$PUB" > /var/www/html/whoami.txt

systemctl restart httpd

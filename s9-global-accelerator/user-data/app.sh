#!/bin/bash
# Region-coloured page so a failover is visible at a glance, and a plain-text
# endpoint so a poller can assert on it without parsing HTML.
REGION_NAME="__REGION__"
COLOR="__COLOR__"

dnf install -y httpd
systemctl enable --now httpd

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(meta instance-id)
AZ=$(meta placement/availability-zone)

if [ "$COLOR" = "blue" ]; then BG="#0b1020"; FG="#3b82f6"; else BG="#04140c"; FG="#22c55e"; fi

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$REGION_NAME</title>
<style>
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:$BG;color:#e2e8f0}
 .card{border:2px solid $FG;border-radius:14px;padding:32px 48px;text-align:center;
       box-shadow:0 0 60px ${FG}44}
 h1{margin:0;font-size:3rem;letter-spacing:.08em;color:$FG}
 dl{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;margin:16px 0 0;
    font-size:.82rem;text-align:left}
 dt{color:#94a3b8}dd{margin:0;font-family:ui-monospace,monospace;color:$FG}
</style></head>
<body><div class="card">
 <h1>$REGION_NAME</h1>
 <dl><dt>instance</dt><dd>$IID</dd><dt>az</dt><dd>$AZ</dd></dl>
</div></body></html>
EOF

echo "$REGION_NAME $IID" > /var/www/html/whoami.txt
# The health-check target. Kept separate from whoami so it can be made to fail
# on its own — that is how the failover is triggered without killing the host.
echo "ok" > /var/www/html/health

systemctl restart httpd

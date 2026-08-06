#!/bin/bash
# Renders a page showing which ENVIRONMENT and which APP VERSION answered, plus
# the instance id. Those three facts are what make a cutover and a rolling
# refresh visible in a browser instead of only in the console.
#
# __ENVIRONMENT__ and __APP_VERSION__ are substituted by deploy.sh when it
# creates each launch template version.
ENVIRONMENT="__ENVIRONMENT__"
APP_VERSION="__APP_VERSION__"

dnf install -y httpd
systemctl start httpd
systemctl enable httpd

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(meta instance-id)
AZ=$(meta placement/availability-zone)

if [ "$ENVIRONMENT" = "BLUE" ]; then BG="#0b1020"; FG="#3b82f6"; else BG="#04140c"; FG="#22c55e"; fi

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$ENVIRONMENT $APP_VERSION</title>
<style>
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:$BG;color:#e2e8f0}
 .card{border:2px solid $FG;border-radius:14px;padding:32px 44px;text-align:center;
       box-shadow:0 0 60px ${FG}44}
 h1{margin:0;font-size:3.4rem;letter-spacing:.12em;color:$FG}
 .v{font-size:1.3rem;margin:8px 0 16px;color:#cbd5e1}
 dl{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;margin:0;font-size:.82rem;text-align:left}
 dt{color:#94a3b8}dd{margin:0;font-family:ui-monospace,monospace;color:$FG}
</style></head>
<body><div class="card">
 <h1>$ENVIRONMENT</h1>
 <div class="v">app $APP_VERSION</div>
 <dl><dt>instance</dt><dd>$IID</dd><dt>az</dt><dd>$AZ</dd></dl>
</div></body></html>
EOF

# Plain-text endpoint so scripts can assert without parsing HTML.
echo "$ENVIRONMENT $APP_VERSION $IID" > /var/www/html/whoami.txt

systemctl restart httpd

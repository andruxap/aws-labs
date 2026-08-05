#!/bin/bash
# Part A — Apache + a custom page, entirely from User Data.
# Runs as root on first boot. Logs to /var/log/cloud-init-output.log.
dnf update -y
dnf install -y httpd

systemctl start httpd
systemctl enable httpd

chown -R ec2-user:ec2-user /var/www/html

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Apache on Amazon Linux 2023</title>
  <style>
    body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
           background: #0f172a; color: #e2e8f0; display: flex;
           align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px;
            padding: 32px 40px; box-shadow: 0 20px 40px rgba(0,0,0,.35); }
    h1 { margin: 0 0 4px; font-size: 1.5rem; }
    p.sub { margin: 0 0 20px; color: #94a3b8; font-size: .9rem; }
    dl { display: grid; grid-template-columns: auto 1fr; gap: 6px 16px;
         margin: 0; font-size: .9rem; }
    dt { color: #94a3b8; }
    dd { margin: 0; font-family: ui-monospace, "Cascadia Code", monospace; color: #7dd3fc; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Apache is serving</h1>
    <p class="sub">Installed and configured by EC2 User Data at first boot.</p>
    <dl>
      <dt>Instance</dt><dd>$IID</dd>
      <dt>AZ</dt><dd>$AZ</dd>
      <dt>Built</dt><dd>$(date -u +"%Y-%m-%dT%H:%M:%SZ")</dd>
    </dl>
  </div>
</body>
</html>
EOF

systemctl restart httpd

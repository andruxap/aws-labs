#!/bin/bash
# The "on-premises" server: MySQL + a small Node app reading from it.
#
# The course has you run this on your own laptop first. That cannot work here:
# DMS runs inside AWS and has no route to a database behind home NAT. An EC2
# instance standing in for the on-prem box is what the course itself moves to,
# and the migration behaves identically.
set -x
dnf install -y mariadb105-server nodejs npm >/dev/null 2>&1

systemctl enable --now mariadb

# --- schema + seed data -----------------------------------------------------
mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS employee_db;
CREATE USER IF NOT EXISTS 'employee_user'@'%' IDENTIFIED BY 'StrongPassword123';
GRANT ALL PRIVILEGES ON employee_db.* TO 'employee_user'@'%';
-- DMS needs these to read the source
GRANT SELECT, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'employee_user'@'%';
FLUSH PRIVILEGES;

USE employee_db;
CREATE TABLE IF NOT EXISTS employees (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  role VARCHAR(100) NOT NULL,
  location VARCHAR(100) NOT NULL,
  hired_on DATE NOT NULL
);
INSERT INTO employees (name, role, location, hired_on) VALUES
 ('Ada Lovelace',      'Principal Engineer',  'London',   '2019-03-11'),
 ('Grace Hopper',      'Director, Platform',  'New York', '2018-07-02'),
 ('Alan Turing',       'Staff Engineer',      'Cambridge','2020-01-20'),
 ('Katherine Johnson', 'Data Engineer',       'Hampton',  '2021-05-17'),
 ('Linus Torvalds',    'Kernel Engineer',     'Portland', '2017-11-30'),
 ('Radia Perlman',     'Network Architect',   'Seattle',  '2016-02-14'),
 ('Barbara Liskov',    'Distinguished Eng',   'Boston',   '2015-09-09'),
 ('Margaret Hamilton', 'VP Engineering',      'Houston',  '2014-04-25');
SQL

# Bind to all interfaces so DMS can reach it.
sed -i 's/^bind-address.*/bind-address=0.0.0.0/' /etc/my.cnf.d/mariadb-server.cnf 2>/dev/null || true
grep -q '^bind-address' /etc/my.cnf.d/mariadb-server.cnf 2>/dev/null || \
  sed -i '/^\[mysqld\]/a bind-address=0.0.0.0' /etc/my.cnf.d/mariadb-server.cnf
systemctl restart mariadb

# --- the application --------------------------------------------------------
mkdir -p /opt/app && cd /opt/app
npm init -y >/dev/null 2>&1
npm install mysql2 >/dev/null 2>&1

# The ONE thing that changes at cutover. Nothing else in the app is touched.
cat > /opt/app/db.env <<EOF
DB_HOST=127.0.0.1
DB_USER=employee_user
DB_PASS=StrongPassword123
DB_NAME=employee_db
EOF

cat > /opt/app/server.js <<'JS'
const http = require('http');
const fs = require('fs');
const mysql = require('mysql2/promise');

function conf() {
  const env = {};
  for (const line of fs.readFileSync('/opt/app/db.env', 'utf8').split('\n')) {
    const [k, v] = line.split('=');
    if (k && v) env[k.trim()] = v.trim();
  }
  return env;
}

http.createServer(async (req, res) => {
  const e = conf();
  try {
    const c = await mysql.createConnection({
      host: e.DB_HOST, user: e.DB_USER, password: e.DB_PASS,
      database: e.DB_NAME, connectTimeout: 5000,
    });
    const [rows] = await c.execute('SELECT id,name,role,location,hired_on FROM employees ORDER BY id');
    const [[v]] = await c.query('SELECT @@version AS v, @@hostname AS h');
    await c.end();

    if (req.url === '/api') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ source: e.DB_HOST, engine: v.v, host: v.h, count: rows.length }));
    }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`<!DOCTYPE html><html><head><meta charset="utf-8"><title>Employee Directory</title>
<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:40px}
table{border-collapse:collapse;margin-top:16px}th,td{border:1px solid #334155;padding:8px 14px;text-align:left}
th{background:#1e293b}.src{color:#38bdf8;font-family:ui-monospace,monospace}</style></head><body>
<h1>Employee Directory</h1>
<p>reading from <span class="src">${e.DB_HOST}</span> &middot; ${v.v} &middot; ${rows.length} rows</p>
<table><tr><th>id</th><th>name</th><th>role</th><th>location</th><th>hired</th></tr>
${rows.map(r => `<tr><td>${r.id}</td><td>${r.name}</td><td>${r.role}</td><td>${r.location}</td><td>${String(r.hired_on).slice(0,15)}</td></tr>`).join('')}
</table></body></html>`);
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end('DB ERROR: ' + err.message + '\nhost=' + e.DB_HOST);
  }
}).listen(80);
JS

cat > /etc/systemd/system/empdir.service <<'UNIT'
[Unit]
Description=Employee Directory
After=network.target
[Service]
ExecStart=/usr/bin/node /opt/app/server.js
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now empdir

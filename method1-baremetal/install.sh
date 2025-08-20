#!/usr/bin/env bash
set -euo pipefail

# === Settings (edit if needed) ===
DNSDIST_LISTEN_IP="0.0.0.0"
DNSDIST_LISTEN_PORT="53"
DNSDIST_ADMIN_HOST="127.0.0.1"
DNSDIST_ADMIN_PORT="5199"
DNSDIST_WEB_HOST="127.0.0.1"
DNSDIST_WEB_PORT="8080"

# Your internal/customer ranges allowed to query DNS
ACL_RANGES=(
  "127.0.0.1/32"
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
)

# Unbound threading
UNBOUND_THREADS="$(nproc)"

# Guacamole version
GUAC_VER="${GUAC_VER:-1.5.5}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-guacRootPass123!}"
GUAC_DB="${GUAC_DB:-guacamole_db}"
GUAC_USER="${GUAC_USER:-guacuser}"
GUAC_PASS="${GUAC_PASS:-GuacUserPass!123}"

echo "[*] Updating APT and installing packages..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  dnsdist unbound unbound-host curl wget ca-certificates \
  ufw jq unzip gnupg lsb-release \
  mariadb-server mariadb-client tomcat9 default-jre-headless \
  guacd

echo "[*] Writing dnsdist.conf ..."
DNSDIST_ACL_LUA="$(printf '"%s", ' "${ACL_RANGES[@]}")"
DNSDIST_ACL_LUA="${DNSDIST_ACL_LUA%, }"

sudo install -d -m 0755 /etc/dnsdist
sudo tee /etc/dnsdist/dnsdist.conf >/dev/null <<EOF
-- dnsdist basic production config (installed by install.sh)
clearBind()
addLocal("${DNSDIST_LISTEN_IP}:${DNSDIST_LISTEN_PORT}", { reusePort=true })

setACL({ ${DNSDIST_ACL_LUA} })

-- Admin endpoints bound to loopback
controlSocket('${DNSDIST_ADMIN_HOST}:${DNSDIST_ADMIN_PORT}')
setKey('$(openssl rand -base64 32)')

webserver('${DNSDIST_WEB_HOST}:${DNSDIST_WEB_PORT}')
setWebserverConfig({
  acl='127.0.0.1/32',
  password='$(openssl rand -hex 16)',
  apiKey='$(openssl rand -hex 16)',
  hashPlaintextCredentials=true,
  apiRequiresAuthentication=true
})

setSecurityPollSuffix('')

-- Backends (edit these to your unbound servers)
newServer({address="127.0.0.1:5311", name="u1", pool="default", checkInterval=5})
newServer({address="127.0.0.1:5312", name="u2", pool="default", checkInterval=5})
newServer({address="127.0.0.1:5313", name="u3", pool="default", checkInterval=5})

setServerPolicy(leastOutstanding)

pc = newPacketCache(200000, { maxTTL=86400, minTTL=60 })
getPool("default"):setCache(pc)

addAction(MaxQPSIPRule(800), DropAction())
addAction(AndRule({QTypeRule(DNSQType.ANY)}), DropAction())

setMaxUDPOutstanding(65536)
setTCPLowLatency(true)
EOF

echo "[*] Writing unbound.conf ..."
sudo install -d -m 0755 /etc/unbound
sudo tee /etc/unbound/unbound.conf >/dev/null <<'EOF'
server:
  interface: 0.0.0.0
  port: 53

  do-ip6: no
  hide-identity: yes
  hide-version: yes
  harden-referral-path: yes
  harden-dnssec-stripped: yes
  aggressive-nsec: yes
  qname-minimisation: yes
  minimal-responses: yes

  cache-min-ttl: 300
  cache-max-ttl: 14400
  prefetch: yes
  prefetch-key: yes
  serve-expired: yes
  serve-expired-ttl: 3600
  serve-expired-client-timeout: 1800

  rrset-cache-size: 256m
  msg-cache-size: 128m
  rrset-cache-slabs: 8
  msg-cache-slabs: 8
  infra-cache-slabs: 8
  key-cache-slabs: 8

  num-threads: 8
  so-reuseport: yes
  so-rcvbuf: 4m
  so-sndbuf: 4m
  outgoing-range: 8192
  num-queries-per-thread: 4096

  access-control: 127.0.0.1/32 allow
  access-control: 10.0.0.0/8 allow
  access-control: 172.16.0.0/12 allow
  access-control: 192.168.0.0/16 allow

  private-address: 192.168.0.0/16
  private-address: 169.254.0.0/16
  private-address: 172.16.0.0/12
  private-address: 10.0.0.0/8
  private-address: fd00::/8
  private-address: fe80::/10

  chroot: ""
  logfile: /var/log/unbound.log
EOF

echo "[*] Creating three Unbound instances on ports 5311..5313"
# Create systemd overrides for three instances using templates
for i in 1 2 3; do
  SVC="unbound@$i.service"
  CFG="/etc/unbound/unbound-$i.conf"
  sudo cp -f /etc/unbound/unbound.conf "$CFG"
  sudo sed -i "s/^  port: .*/  port: 531$i/" "$CFG"
  sudo sed -i "s/^  interface: .*/  interface: 127.0.0.1/" "$CFG"
  # systemd unit
  sudo tee /etc/systemd/system/$SVC >/dev/null <<UNIT
[Unit]
Description=Unbound DNS resolver instance $i
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/unbound -d -c $CFG
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SVC"
done

echo "[*] Enabling/Restarting dnsdist..."
sudo systemctl enable dnsdist
sudo systemctl restart dnsdist

# ---------------- Guacamole (native) ----------------
echo "[*] Setting up MariaDB for Guacamole..."
sudo systemctl enable --now mariadb
sudo mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS ${GUAC_DB} DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${GUAC_USER}'@'%' IDENTIFIED BY '${GUAC_PASS}';
GRANT ALL PRIVILEGES ON ${GUAC_DB}.* TO '${GUAC_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "[*] Downloading Guacamole ${GUAC_VER} artifacts..."
TMP="$(mktemp -d)"
pushd "$TMP" >/dev/null
curl -fL -o guacamole.war "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war"
curl -fL -o guacamole-auth-jdbc.tar.gz "https://archive.apache.org/dist/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz"
curl -fL -o mysql-connector-j.zip "https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j-8.4.0.zip"

echo "[*] Installing Guacamole server (Tomcat + extensions) ..."
sudo install -D -m 0644 guacamole.war /var/lib/tomcat9/webapps/guacamole.war
sudo install -d -m 0755 /etc/guacamole/extensions /etc/guacamole/lib

# Unpack JDBC auth + MySQL driver
tar -xzf guacamole-auth-jdbc.tar.gz
JDBC_DIR="$(find . -maxdepth 1 -type d -name 'guacamole-auth-jdbc-*' | head -n1)"
sudo install -m 0644 "$JDBC_DIR/mysql/guacamole-auth-jdbc-mysql-*.jar" /etc/guacamole/extensions/

unzip -q mysql-connector-j.zip -d .
MYSQL_JAR="$(find . -type f -name 'mysql-connector-j-*.jar' | head -n1)"
sudo install -m 0644 "$MYSQL_JAR" /etc/guacamole/lib/

# Init DB schema
cat "$JDBC_DIR/mysql/schema/001-create-schema.sql" \
    "$JDBC_DIR/mysql/schema/002-create-admin-user.sql" \
    "$JDBC_DIR/mysql/schema/003-create-indexes.sql" \
    > guac-init.sql

# Set default admin user/pass to guacadmin/guacadmin (you must change)
sudo mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" ${GUAC_DB} < guac-init.sql

# guacamole.properties
sudo tee /etc/guacamole/guacamole.properties >/dev/null <<PROP
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: ${GUAC_DB}
mysql-username: ${GUAC_USER}
mysql-password: ${GUAC_PASS}
# Place to store extensions and libs
lib-directory: /etc/guacamole/lib
extension-directory: /etc/guacamole/extensions
# Allow admin account login
mysql-auto-create-accounts: true
PROP

# Tomcat looks for ~/.guacamole -> point it to /etc/guacamole
sudo install -d -m 0755 /usr/share/tomcat9/.guacamole
sudo ln -sf /etc/guacamole /usr/share/tomcat9/.guacamole

popd >/dev/null
rm -rf "$TMP"

echo "[*] Restarting guacd and tomcat9..."
sudo systemctl restart guacd
sudo systemctl restart tomcat9

echo
echo "============================================================"
echo "DONE!"
echo "- dnsdist listening on ${DNSDIST_LISTEN_IP}:${DNSDIST_LISTEN_PORT}"
echo "- Unbound instances on 127.0.0.1:5311, 5312, 5313"
echo "- Guacamole at: http://<this-host>:8080/guacamole  (login: guacadmin/guacadmin)"
echo "  Change the default password immediately from the UI."
echo
echo "Test:"
echo "  dig @127.0.0.1 -p 5353 openai.com   # if you NAT dnsdist to 5353 for testing"
echo "  or dig @<server-ip> openai.com"
echo "============================================================"

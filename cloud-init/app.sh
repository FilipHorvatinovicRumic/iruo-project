#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/techsprint-app-init.log) 2>&1
hostnamectl set-hostname __HOSTNAME__
for i in $(seq 1 90); do
  if curl -fsS --max-time 5 https://packages.microsoft.com >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
DATADEV=/dev/disk/azure/scsi1/lun0
for i in $(seq 1 60); do
  [ -e "$DATADEV" ] && break
  sleep 5
done
mkdir -p /data
if ! blkid "$DATADEV" >/dev/null 2>&1; then
  mkfs.xfs -f "$DATADEV"
fi
UUID=$(blkid -s UUID -o value "$DATADEV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data xfs defaults,nofail 0 2" >> /etc/fstab
mount -a
mkdir -p /data/moodledata /data/blob-cache /mnt/moodle-object /mnt/moodle-backup
dnf -y install curl tar unzip nfs-utils httpd mariadb-server php php-cli php-common php-mysqlnd php-gd php-intl php-mbstring php-opcache php-pdo php-soap php-xml php-process php-pecl-zip policycoreutils-python-utils
systemctl enable --now mariadb httpd
mysql -e "CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY 'TsMoodleDB-2026!';"
mysql -e "GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'localhost'; FLUSH PRIVILEGES;"
if [ ! -f /var/www/moodle/config.php ]; then
  rm -rf /var/www/moodle /tmp/moodle.tgz
  curl -fL --retry 5 --retry-delay 10 -o /tmp/moodle.tgz https://download.moodle.org/download.php/direct/stable401/moodle-latest-401.tgz
  tar -xzf /tmp/moodle.tgz -C /var/www
  chown -R apache:apache /var/www/moodle /data/moodledata
  sudo -u apache php /var/www/moodle/admin/cli/install.php --non-interactive --lang=en --wwwroot="http://__LB_IP__" --dataroot=/data/moodledata --dbtype=mariadb --dbhost=localhost --dbname=moodle --dbuser=moodle --dbpass='TsMoodleDB-2026!' --fullname="TechSprint Moodle - __DEV_DISPLAY__" --shortname="TS-__DEV_SLUG__" --adminuser=admin --adminpass='TsMoodleAdmin-2026!' --adminemail=admin@example.invalid --agree-license
fi
cat >/etc/httpd/conf.d/moodle.conf <<'APACHE'
<VirtualHost *:80>
    DocumentRoot /var/www/moodle
    <Directory /var/www/moodle>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHE
chown -R apache:apache /var/www/moodle /data/moodledata
setsebool -P httpd_can_network_connect 1 || true
semanage fcontext -a -t httpd_sys_rw_content_t '/data/moodledata(/.*)?' 2>/dev/null || true
restorecon -Rv /data/moodledata || true
systemctl restart httpd
FILEHOST="__FILE_ACCOUNT__.file.core.windows.net"
FSTAB_LINE="$FILEHOST:/__FILE_ACCOUNT__/moodle-backups /mnt/moodle-backup nfs vers=4,minorversion=1,sec=sys,nconnect=4,noresvport,_netdev,nofail 0 0"
grep -Fq "$FILEHOST:/__FILE_ACCOUNT__/moodle-backups" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
for i in $(seq 1 30); do
  mount /mnt/moodle-backup && break || true
  sleep 10
done
rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
curl -fsSL --retry 5 -o /tmp/packages-microsoft-prod.rpm https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
rpm -Uvh --replacepkgs /tmp/packages-microsoft-prod.rpm || true
dnf -y install blobfuse2
cat >/etc/blobfuse2-techsprint.yaml <<BLOB
allow-other: true
components:
  - libfuse
  - file_cache
  - attr_cache
  - azstorage
file_cache:
  path: /data/blob-cache
  timeout-sec: 120
azstorage:
  type: block
  account-name: __BLOB_ACCOUNT__
  container: moodle-files
  endpoint: blob.core.windows.net
  mode: msi
BLOB
cat >/etc/systemd/system/techsprint-blobfuse.service <<'UNIT'
[Unit]
Description=TechSprint Moodle BlobFuse2 mount
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/blobfuse2 mount /mnt/moodle-object --config-file=/etc/blobfuse2-techsprint.yaml
ExecStop=/bin/fusermount3 -u /mnt/moodle-object
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable techsprint-blobfuse.service
systemctl restart techsprint-blobfuse.service || true
cat >/var/www/html/techsprint-health.txt <<HEALTH
hostname=$(hostname)
developer=__DEV_DISPLAY__
load_balancer=__LB_IP__
data_disk=$(findmnt -n -o SOURCE /data 2>/dev/null || true)
file_storage=$(findmnt -n -o SOURCE /mnt/moodle-backup 2>/dev/null || true)
blob_storage=$(findmnt -n -o SOURCE /mnt/moodle-object 2>/dev/null || true)
HEALTH

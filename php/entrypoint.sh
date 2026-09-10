#!/bin/bash
set -e

# Cho phep ghi tu do, tranh loi permission tren Windows/WSL/Linux
echo "Setting permissions (777)..."
mkdir -p /var/www/moodledata /var/log/moodle /var/log/php
chown -R www-data:www-data /var/www/html /var/www/moodledata /var/log/moodle /var/log/php || true
chmod -R 777 /var/www/html /var/www/moodledata
chmod -R 777 /var/log/moodle /var/log/php

# ACL mac dinh: file moi tao (ca trong container lan ngoai host)
# deu ghi duoc 2 chieu, khong can chmod lai
for d in /var/www/html /var/www/moodledata; do
  setfacl -R -m u::rwx,g::rwx,o::rwx,d:u::rwx,d:g::rwx,d:o::rwx "$d" 2>/dev/null || true
done

if [ -f "/var/www/html/composer.json" ]; then
  echo "Installing Composer dependencies..."
  composer install --no-dev --classmap-authoritative --no-interaction
fi

echo "Starting Apache..."
exec apache2-foreground

#!/bin/bash
# install_cacti.sh — Install Cacti 1.2.30 on Ubuntu 24.04 (Fixed & Optimized)

set -e

echo "=========================================="
echo "🚀 Installing Cacti 1.2.30 on Ubuntu 24.04"
echo "=========================================="

# Step 1: Update system
echo "[1/10] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y

# Step 2: Install required dependencies
echo "[2/10] Installing dependencies..."
sudo apt install -y apache2 mariadb-server php php-mysql libapache2-mod-php \
php-snmp php-ldap php-xml php-mbstring php-gd php-json php-zip php-cli \
php-common php-curl php-gmp php-bcmath php-intl php-readline php-pdo php-xmlrpc \
php-pear snmp snmpd rrdtool git unzip

# Ensure gmp and hash modules are enabled
sudo phpenmod gmp
sudo phpenmod hash

# Step 3: Tune PHP settings
echo "[3/10] Adjusting PHP configuration..."
sudo sed -i 's/^memory_limit.*/memory_limit = 512M/' /etc/php/8.3/apache2/php.ini
sudo sed -i 's/^max_execution_time.*/max_execution_time = 300/' /etc/php/8.3/apache2/php.ini
sudo systemctl restart apache2

# Step 4: Secure and start MariaDB
echo "[4/10] Securing MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb
sudo mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('rootpass');"
sudo mysql -e "DELETE FROM mysql.user WHERE User='';"
sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');"
sudo mysql -e "DROP DATABASE IF EXISTS test;"
sudo mysql -e "FLUSH PRIVILEGES;"

# Step 5: Create Cacti database and user
echo "[5/10] Creating database and user..."
sudo mysql -u root -prootpass -e "CREATE DATABASE cacti CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -prootpass -e "CREATE USER 'cactiuser'@'localhost' IDENTIFIED BY 'cactipass';"
sudo mysql -u root -prootpass -e "GRANT ALL PRIVILEGES ON cacti.* TO 'cactiuser'@'localhost';"
sudo mysql -u root -prootpass -e "GRANT SELECT ON mysql.time_zone_name TO 'cactiuser'@'localhost';"
sudo mysql -u root -prootpass -e "FLUSH PRIVILEGES;"
sudo mysql_tzinfo_to_sql /usr/share/zoneinfo | sudo mysql -u root -prootpass mysql


# Step 6: Optimize MariaDB for Cacti
echo "[6/10] Optimizing MariaDB..."
sudo tee /etc/mysql/mariadb.conf.d/90-cacti.cnf > /dev/null <<EOF
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_heap_table_size = 64M
tmp_table_size = 64M
join_buffer_size = 64M
sort_buffer_size = 4M
innodb_file_per_table = ON
innodb_buffer_pool_size = 1G
max_allowed_packet = 16777216
innodb_doublewrite = 0
innodb_use_atomic_writes = 1
EOF
sudo systemctl restart mariadb

# Step 7: Download and extract Cacti 1.2.30
echo "[7/10] Downloading Cacti 1.2.30..."
cd /tmp
wget https://files.cacti.net/cacti/linux/cacti-1.2.30.tar.gz
tar -xzf cacti-1.2.30.tar.gz
sudo mv cacti-1.2.30 /var/www/html/cacti

# Step 8: Import default database
echo "[8/10] Importing initial database schema..."
sudo mysql -u cactiuser -pcactipass cacti < /var/www/html/cacti/cacti.sql

# Step 9: Configure Cacti
echo "[9/10] Configuring Cacti..."
sudo cp /var/www/html/cacti/include/config.php.dist /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_username.*/\$database_username = 'cactiuser';/" /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_password.*/\$database_password = 'cactipass';/" /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_default.*/\$database_default = 'cacti';/" /var/www/html/cacti/include/config.php

sudo chown -R www-data:www-data /var/www/html/cacti
sudo chmod -R 755 /var/www/html/cacti

# Step 10: Apache config and cron
echo "[10/10] Setting up Apache and cron..."
sudo tee /etc/apache2/sites-available/cacti.conf > /dev/null <<EOF
Alias /cacti /var/www/html/cacti
<Directory /var/www/html/cacti>
    Options +FollowSymLinks
    AllowOverride All
    <IfModule mod_authz_core.c>
        Require all granted
    </IfModule>
</Directory>
EOF

sudo a2ensite cacti.conf
sudo a2enmod php8.3
sudo systemctl reload apache2

sudo tee /etc/cron.d/cacti > /dev/null <<EOF
*/5 * * * * www-data php /var/www/html/cacti/poller.php > /dev/null 2>&1
EOF

sudo systemctl restart apache2
sudo systemctl restart snmpd

echo "=========================================="
echo "✅ Cacti 1.2.30 installation complete!"
echo "Access: http://<your-server-ip>/cacti"
echo "Login: admin / admin"
echo "=========================================="


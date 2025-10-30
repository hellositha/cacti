#!/bin/bash
# install_cacti.sh — Auto-repair & Install Cacti 1.2.30 on Ubuntu 24.04
# Updated with MySQL/MariaDB & BLAS self-healing fixes

set -e

echo "=========================================="
echo "🚀 Installing Cacti 1.2.30 on Ubuntu 24.04"
echo "=========================================="

# Step 0: Auto-heal system before install
echo "[0/11] Checking system integrity..."

# Check for bad libblas file
if [ -L /usr/lib/x86_64-linux-gnu/blas/libblas.so.3 ] || [ -f /usr/lib/x86_64-linux-gnu/blas/libblas.so.3 ]; then
    if ! ldconfig -p | grep -q "libblas.so.3"; then
        echo "⚠️ Detected broken libblas.so.3 — attempting repair..."
        if [ -f /mnt/iso/pool/main/l/libblas/libblas3_*.deb ]; then
            echo "📀 Reinstalling libblas3 from local ISO..."
            sudo dpkg -i /mnt/iso/pool/main/l/libblas/libblas3_*.deb || true
        else
            echo "🌐 Reinstalling libblas3 from apt..."
            sudo apt install --reinstall -y libblas3 || true
        fi
    fi
else
    echo "ℹ️ libblas.so.3 not found — installing libblas3..."
    sudo apt install -y libblas3 || true
fi

# Fix half-installed MySQL or MariaDB packages
echo "🩹 Repairing MySQL/MariaDB configuration..."
sudo dpkg --configure -a || true
sudo apt -f install -y || true

# Clean old locks if dpkg stuck
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "🔓 Unlocking dpkg..."
    sudo fuser -vki /var/lib/dpkg/lock-frontend
    sudo rm -f /var/lib/dpkg/lock-frontend
fi

echo "✅ System integrity check completed."
sleep 2

# Step 1: Update system
echo "[1/11] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y

# Step 2: Install dependencies
echo "[2/11] Installing dependencies..."
sudo apt install -y apache2 mariadb-server php php-mysql libapache2-mod-php \
php-snmp php-ldap php-xml php-mbstring php-gd php-json php-zip php-cli \
php-common php-curl php-gmp php-bcmath php-intl php-readline php-pdo php-xmlrpc \
php-pear snmp snmpd rrdtool git unzip tzdata wget psmisc socat

# Enable necessary PHP modules
sudo phpenmod gmp hash

# Detect PHP version dynamically
PHPVER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

# Step 3: Tune PHP
echo "[3/11] Adjusting PHP configuration..."
sudo sed -i 's/^memory_limit.*/memory_limit = 512M/' /etc/php/$PHPVER/apache2/php.ini
sudo sed -i 's/^max_execution_time.*/max_execution_time = 300/' /etc/php/$PHPVER/apache2/php.ini
sudo systemctl restart apache2

# Step 4: Secure MariaDB
echo "[4/11] Securing MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'rootpass';" || true
sudo mysql -u root -prootpass -e "DELETE FROM mysql.user WHERE User='';" || true
sudo mysql -u root -prootpass -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');" || true
sudo mysql -u root -prootpass -e "DROP DATABASE IF EXISTS test;" || true
sudo mysql -u root -prootpass -e "FLUSH PRIVILEGES;" || true
sudo mysql_tzinfo_to_sql /usr/share/zoneinfo | sudo mysql -u root -prootpass mysql || true

# Step 5: Create Cacti DB
echo "[5/11] Creating database and user..."
sudo mysql -u root -prootpass -e "CREATE DATABASE IF NOT EXISTS cacti CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -prootpass -e "CREATE USER IF NOT EXISTS 'cactiuser'@'localhost' IDENTIFIED BY 'cactipass';"
sudo mysql -u root -prootpass -e "GRANT ALL PRIVILEGES ON cacti.* TO 'cactiuser'@'localhost';"
sudo mysql -u root -prootpass -e "GRANT SELECT ON mysql.time_zone_name TO 'cactiuser'@'localhost';"
sudo mysql -u root -prootpass -e "FLUSH PRIVILEGES;"

# Step 6: Optimize MariaDB for Cacti
echo "[6/11] Optimizing MariaDB..."
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

# Step 7: Download Cacti
echo "[7/11] Downloading and extracting Cacti 1.2.30..."
cd /tmp
wget -q https://files.cacti.net/cacti/linux/cacti-1.2.30.tar.gz -O cacti.tar.gz
tar -xzf cacti.tar.gz
sudo mv cacti-1.2.30 /var/www/html/cacti

# Step 8: Import default database
echo "[8/11] Importing Cacti database..."
sudo mysql -u cactiuser -pcactipass cacti < /var/www/html/cacti/cacti.sql

# Step 9: Configure Cacti
echo "[9/11] Configuring Cacti..."
sudo cp /var/www/html/cacti/include/config.php.dist /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_username.*/\$database_username = 'cactiuser';/" /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_password.*/\$database_password = 'cactipass';/" /var/www/html/cacti/include/config.php
sudo sed -i "s/\$database_default.*/\$database_default = 'cacti';/" /var/www/html/cacti/include/config.php
sudo chown -R www-data:www-data /var/www/html/cacti
sudo chmod -R 755 /var/www/html/cacti

# Step 10: Apache configuration (Root access)
echo "[10/11] Configuring Apache..."
sudo tee /etc/apache2/sites-available/000-default.conf > /dev/null <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/cacti
    <Directory /var/www/html/cacti>
        Options +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

sudo a2enmod rewrite
sudo a2enmod php$PHPVER
sudo systemctl reload apache2

# Step 11: Cron and SNMP
echo "[11/11] Setting up cron and SNMP..."
sudo tee /etc/cron.d/cacti > /dev/null <<EOF
*/5 * * * * www-data php /var/www/html/cacti/poller.php > /dev/null 2>&1
EOF
sudo systemctl enable snmpd
sudo systemctl restart snmpd
sudo systemctl restart apache2

# Optional: Allow through UFW
if command -v ufw &> /dev/null; then
    sudo ufw allow 80/tcp || true
    sudo ufw allow 161/udp || true
fi

echo "=========================================="
echo "✅ Cacti 1.2.30 installation complete!"
echo "🌐 Access: http://$(hostname -I | awk '{print $1}')/cacti/"
echo "🔑 Login: admin / admin"
echo "=========================================="

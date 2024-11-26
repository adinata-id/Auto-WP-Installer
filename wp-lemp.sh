#!/bin/bash

clear
echo "Install WordPress dengan LEMP di Ubuntu"
echo "----------------------"
echo "Spesifikasi:"
echo "1. Nginx terbaru"
echo "2. PHP 8.1, 8.2, 8.3"
echo "3. MariaDB 10.11"
echo "4. SSL Let's Encrypt"
echo "5. WordPress dengan opsi versi & multisite"
echo "----------------------"

ip=$(wget -qO- http://ipecho.net/plain | xargs echo)

echo "Informasi Domain dan WordPress"
echo "----------------------"
read -p "Domain(1) atau Subdomain(2) [1/2] = " tipedomain
read -p "Nama domain = " domain
read -p "Versi PHP [8.1/8.2/8.3] = " vphp
read -p "Email notifikasi SSL = " emailssl
read -p "Judul website = " wptitle
read -p "Username admin = " wpadmin
read -p "Email admin = " wpemail
read -p "Password admin (kosongkan untuk auto-generate) = " wpadminpass
read -p "Install WordPress versi terbaru? [y/n] = " wp_latest
if [ "$wp_latest" = "n" ]; then
    read -p "Masukkan versi WordPress yang diinginkan (contoh: 6.4.3): " wp_version
fi
read -p "Install WordPress Multisite? [y/n] = " wp_multisite
if [ "$wp_multisite" = "y" ]; then
    read -p "Tipe Multisite - subdomain(1) atau subdirectory(2) [1/2]: " multisite_type
fi

# Generate password if empty
if [ -z "$wpadminpass" ]; then
    wpadminpass=$(pwgen 20 1)
    echo "Password admin di-generate: $wpadminpass"
fi

echo "Memulai instalasi dan konfigurasi ..."
echo "----------------------"
echo "Set TimeZone Asia/Jakarta"
timedatectl set-timezone Asia/Jakarta

echo "Update & Upgrade Sistem"
apt update -y && apt upgrade -y
apt install software-properties-common pwgen curl wget unzip nginx -y

echo "Tambah Repository PHP"
add-apt-repository ppa:ondrej/php -y
apt update -y

echo "Install PHP $vphp dan Extensions"
apt install php$vphp php$vphp-fpm php$vphp-common php$vphp-cli php$vphp-mbstring \
php$vphp-gd php$vphp-intl php$vphp-xml php$vphp-mysql php$vphp-zip php$vphp-curl \
php$vphp-bcmath php$vphp-imagick php$vphp-soap php$vphp-xmlrpc -y

# PHP Optimization
cat > /etc/php/$vphp/fpm/conf.d/custom.ini << EOF
upload_max_filesize = 200M
post_max_size = 200M
max_execution_time = 600
max_input_time = 600
memory_limit = 256M
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
EOF

systemctl restart php$vphp-fpm

echo "Install MariaDB"
apt install mariadb-server -y
mysql_secure_installation

echo "Membuat Database dan User"
dbname="wp_${domain//./}"
dbuser="usr_${domain//./}"
dbpass=$(pwgen 20 1)

mysql << EOF
CREATE DATABASE ${dbname};
CREATE USER '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "Membuat Document Root"
mkdir -p /var/www/${domain}
chown -R www-data:www-data /var/www/${domain}
chmod -R 755 /var/www/${domain}

cd /var/www/${domain}
rm -f index.php

echo "Downloading WordPress..."
if [ "$wp_latest" = "y" ]; then
    wget https://wordpress.org/latest.zip
    unzip latest.zip
    mv wordpress/* .
    rm -rf wordpress latest.zip
else
    wget https://wordpress.org/wordpress-${wp_version}.zip
    unzip wordpress-${wp_version}.zip
    mv wordpress/* .
    rm -rf wordpress wordpress-${wp_version}.zip
fi

# Create wp-config.php
wp config create --dbname=${dbname} --dbuser=${dbuser} --dbpass=${dbpass} --dbhost=localhost --allow-root

# Configure Nginx based on installation type
if [ "$wp_multisite" = "y" ]; then
    if [ "$multisite_type" = "1" ]; then
        # Subdomain multisite configuration
        cat > /etc/nginx/sites-available/${domain} << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} *.${domain};
    root /var/www/${domain};
    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${vphp}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }

    # Multisite specific rewrites
    if (!-e \$request_filename) {
        rewrite /wp-admin\$ \$scheme://\$host\$uri/ permanent;
        rewrite ^/[_0-9a-zA-Z-]+(/wp-.*) \$1 last;
        rewrite ^/[_0-9a-zA-Z-]+(/.*\.php)\$ \$1 last;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|woff|ttf|svg|eot)\$ {
        expires max;
        log_not_found off;
        access_log off;
    }

    location ~ /\. { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }

    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;
}
EOF

        # Install WordPress multisite with subdomain
        wp core multisite-install --url=https://${domain} \
            --title="${wptitle}" \
            --admin_user="${wpadmin}" \
            --admin_password="${wpadminpass}" \
            --admin_email="${wpemail}" \
            --subdomains \
            --allow-root

        # Configure wp-config.php for multisite
        wp config set WP_ALLOW_MULTISITE true --raw --allow-root
        wp config set MULTISITE true --raw --allow-root
        wp config set SUBDOMAIN_INSTALL true --raw --allow-root
        wp config set DOMAIN_CURRENT_SITE "${domain}" --allow-root
        wp config set PATH_CURRENT_SITE "/" --allow-root
        wp config set SITE_ID_CURRENT_SITE 1 --raw --allow-root
        wp config set BLOG_ID_CURRENT_SITE 1 --raw --allow-root

    else
        # Subdirectory multisite configuration
        cat > /etc/nginx/sites-available/${domain} << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root /var/www/${domain};
    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${vphp}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|woff|ttf|svg|eot)\$ {
        expires max;
        log_not_found off;
        access_log off;
    }

    location ~ /\. { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }

    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;
}
EOF

        # Install WordPress multisite with subdirectory
        wp core multisite-install --url=https://${domain} \
            --title="${wptitle}" \
            --admin_user="${wpadmin}" \
            --admin_password="${wpadminpass}" \
            --admin_email="${wpemail}" \
            --allow-root

        # Configure wp-config.php for multisite
        wp config set WP_ALLOW_MULTISITE true --raw --allow-root
        wp config set MULTISITE true --raw --allow-root
        wp config set SUBDOMAIN_INSTALL false --raw --allow-root
        wp config set DOMAIN_CURRENT_SITE "${domain}" --allow-root
        wp config set PATH_CURRENT_SITE "/" --allow-root
        wp config set SITE_ID_CURRENT_SITE 1 --raw --allow-root
        wp config set BLOG_ID_CURRENT_SITE 1 --raw --allow-root
    fi
else
    # Single site configuration
    cat > /etc/nginx/sites-available/${domain} << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    root /var/www/${domain};
    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${vphp}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico)\$ {
        expires max;
        log_not_found off;
    }

    location ~ /\. { deny all; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }

    access_log /var/log/nginx/${domain}_access.log;
    error_log /var/log/nginx/${domain}_error.log;
}
EOF

    # Install WordPress single site
    wp core install --url=https://${domain} \
        --title="${wptitle}" \
        --admin_user="${wpadmin}" \
        --admin_password="${wpadminpass}" \
        --admin_email="${wpemail}" \
        --allow-root
fi

# Set correct permissions
chown -R www-data:www-data /var/www/${domain}
find /var/www/${domain} -type d -exec chmod 755 {} \;
find /var/www/${domain} -type f -exec chmod 644 {} \;

# Enable site and restart Nginx
ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# Install and configure SSL
apt install certbot python3-certbot-nginx -y
if [ $tipedomain == 1 ]; then
    if [ "$wp_multisite" = "y" ] && [ "$multisite_type" = "1" ]; then
        certbot --non-interactive -m ${emailssl} --agree-tos --no-eff-email --nginx -d ${domain} -d *.${domain} --redirect
    else
        certbot --non-interactive -m ${emailssl} --agree-tos --no-eff-email --nginx -d ${domain} -d www.${domain} --redirect
    fi
else
    certbot --non-interactive -m ${emailssl} --agree-tos --no-eff-email --nginx -d ${domain} --redirect
fi

# Save configuration
cat > /root/${domain}-conf.txt << EOF
IP Server = ${ip}
Domain = ${domain}
Email Let's Encrypt = ${emailssl}

Document Root = /var/www/${domain}
Server Block Conf = /etc/nginx/sites-available/${domain}

Nama Database = ${dbname}
User Database = ${dbuser}
Password Database = ${dbpass}

WP Admin User = ${wpadmin}
WP Admin Email = ${wpemail}
WP Admin Password = ${wpadminpass}

Installation Type = $([ "$wp_multisite" = "y" ] && echo "Multisite ($([ "$multisite_type" = "1" ] && echo "Subdomain" || echo "Subdirectory"))" || echo "Single Site")
EOF

echo
echo "Instalasi WordPress dengan LEMP sudah selesai"
echo "Informasi konfigurasi tersimpan di /root/${domain}-conf.txt"
echo
cat /root/${domain}-conf.txt
echo
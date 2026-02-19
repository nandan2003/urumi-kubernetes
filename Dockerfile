FROM wordpress:php8.2-apache

USER root

RUN set -e; \
  apt-get update; \
  apt-get install -y --no-install-recommends curl unzip ca-certificates; \
  rm -rf /var/lib/apt/lists/*; \
  curl -fSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
  chmod +x /usr/local/bin/wp; \
  echo "memory_limit=512M" > /usr/local/etc/php/conf.d/urumi-memory.ini; \
  curl -fSL -o /tmp/woocommerce.zip https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip; \
  unzip -q /tmp/woocommerce.zip -d /usr/src/wordpress/wp-content/plugins; \
  rm -f /tmp/woocommerce.zip; \
  curl -fSL -o /tmp/storefront.zip https://downloads.wordpress.org/theme/storefront.latest-stable.zip; \
  unzip -q /tmp/storefront.zip -d /usr/src/wordpress/wp-content/themes; \
  rm -f /tmp/storefront.zip; \
  chown -R www-data:www-data /usr/src/wordpress/wp-content

USER www-data

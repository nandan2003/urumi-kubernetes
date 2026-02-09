FROM wordpress:php8.2-apache

USER root

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl unzip \
  && rm -rf /var/lib/apt/lists/*

RUN curl -sS -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  && chmod +x /usr/local/bin/wp

RUN curl -sSL -o /tmp/woocommerce.zip https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip \
  && unzip -q /tmp/woocommerce.zip -d /usr/src/wordpress/wp-content/plugins \
  && rm -f /tmp/woocommerce.zip

RUN curl -sSL -o /tmp/storefront.zip https://downloads.wordpress.org/theme/storefront.latest-stable.zip \
  && unzip -q /tmp/storefront.zip -d /usr/src/wordpress/wp-content/themes \
  && rm -f /tmp/storefront.zip

RUN chown -R www-data:www-data /usr/src/wordpress/wp-content

USER www-data

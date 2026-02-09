#!/bin/sh
set +e
wp wc product create --name='Engine String Bag (Big Logo)' --regular_price=19.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This fashionable string bag is made of 100% cotton. It is the perfect size for carrying your everyday essentials.' || true
wp wc product create --name='Engine String Bag (Small Logos)' --regular_price=19.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This fashionable string bag is made of 100% cotton. It is the perfect size for carrying your everyday essentials.' || true
wp wc product create --name='Brand Buttons' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='Represent your favorite CMS, eCommerce Platform, Website Builder, or Plugin Company in style with a cool pin.' || true
wp wc product create --name='Brand Buttons' --regular_price=9.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --description='Rep your love!' || true
wp wc product create --name='Brand Buttons - Engine' --regular_price=9.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --description='Rep your love for Engine!' || true
wp wc product create --name='Brand Buttons - WooCommerce' --regular_price=9.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --description='Rep your love for WooCommerce!' || true
wp wc product create --name='Brand Buttons - WordPress' --regular_price=9.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --description='Rep your love for WordPress!' || true
wp wc product create --name=Lanyard --regular_price=9.99 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='Stop losing your important access keys with a lanyard that is ALMOST as reliable as Engine plugins!' || true
wp wc product create --name='Engine Tee' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton t-shirt that features the Engine logo on the front is perfect for any occasion. The shirt is available in three colors.' || true
wp wc product create --name='Engine Tee - Blue, Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - White, Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - Yellow, Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - Blue, Medium' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - White, Medium' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - Yellow, Medium' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - Blue, Small' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - White, Small' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Tee - Yellow, Small' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name=Tee --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton t-shirt features the logo on the front and back. It is the perfect tee for any occasion.' || true
wp wc product create --name='Tee - Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Tee - Medium' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Tee - Small' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WordPress Tee' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton t-shirt features the WordPress logo on the front and back. It is the perfect tee for any occasion.' || true
wp wc product create --name='WordPress Tee - Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WordPress Tee - Medium' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WordPress Tee - Small' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens Hoodie' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This hoodie is a must have for any fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your pride.' || true
wp wc product create --name='Mens Hoodie - Large' --regular_price=39.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens Hoodie - Medium' --regular_price=34.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens Hoodie - Small' --regular_price=34.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Dat Engine Life Hoodie - Limited Edition' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This Engine hoodie is a must have for any Engine fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your Engine pride.' || true
wp wc product create --name='Dat Engine Life Hoodie - Limited Edition - Large' --regular_price=44.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Dat Engine Life Hoodie - Limited Edition - Medium' --regular_price=44.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Dat Engine Life Hoodie - Limited Edition - Small' --regular_price=44.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens WordPress Hoodie' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This WordPress hoodie is a must have for any WordPress fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your WordPress pride.' || true
wp wc product create --name='Mens WordPress Hoodie - Large' --regular_price=34.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens WordPress Hoodie - Medium' --regular_price=34.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Mens WordPress Hoodie - Small' --regular_price=34.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Logo Zipper Hoodie' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This Engine hoodie is a must have for any Engine fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your Engine pride.' || true
wp wc product create --name='Engine Logo Zipper Hoodie - Large' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Logo Zipper Hoodie - Medium' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Engine Logo Zipper Hoodie - Small' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Purple Engine Text Zipper Hoodie' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This Engine hoodie is a must have for any Engine fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your Engine pride.' || true
wp wc product create --name='Purple Engine Text Zipper Hoodie - Large' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Purple Engine Text Zipper Hoodie - Medium' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Purple Engine Text Zipper Hoodie - Small' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WooCommerce "Gimme the Money" Zipper Hoodie' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This WooCommerce hoodie is a must have for any WooCommerce fan. It is made from a soft, comfortable, and durable cotton blend. The hoodie is a perfect way to stay warm and show your WooCommerce pride.' || true
wp wc product create --name='WooCommerce "Gimme the Money" Zipper Hoodie - Large' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WooCommerce "Gimme the Money" Zipper Hoodie - Medium' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='WooCommerce "Gimme the Money" Zipper Hoodie - Small' --regular_price=29.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Ninja Tee' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton t-shirt features the logo on the front and expresses your Ninja status with the theme. It is the perfect tee for any occasion.' || true
wp wc product create --name='Ninja Tee - Large' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Ninja Tee - Medium' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Ninja Tee - Small' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton crop-top features the and Engine logos on the front and back. It is the perfect tee for any occasion.' || true
wp wc product create --name='Dat Engine Life Crop-top (3-Tone)' --regular_price=10 --status=publish --user=${WP_ADMIN_USER} --allow-root --short_description='This comfortable cotton crop-top features the Engine logo on the front expressing how easy "data Engine life" is. It is the perfect tee for any occasion.' || true
wp wc product create --name='Dat Engine Life Crop-top (3-Tone) - Large' --regular_price=14.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Dat Engine Life Crop-top (3-Tone) - Medium' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Dat Engine Life Crop-top (3-Tone) - Small' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Large, Blue' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Large, White' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Large, Yellow' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Medium, Blue' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Medium, White' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Medium, Yellow' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Small, Blue' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Small, White' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true
wp wc product create --name='Simplified Crop-top - Small, Yellow' --regular_price=12.99 --status=publish --user=${WP_ADMIN_USER} --allow-root || true

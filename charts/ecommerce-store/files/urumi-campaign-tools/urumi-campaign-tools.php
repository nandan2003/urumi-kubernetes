<?php
/**
 * Plugin Name: Urumi Campaign Tools
 * Description: Safe banner/popup/email helpers for Urumi AI orchestration.
 * Version: 0.1.0
 */

if (!defined('ABSPATH')) {
    exit;
}

class Urumi_Campaign_Tools {
    const BANNER_OPTION = 'urumi_banner_settings';
    const POPUP_OPTION = 'urumi_popup_settings';
    const EMAIL_LOGGING_OPTION = 'urumi_email_logging_threshold';
    const EMAIL_PREVIEW_OPTION = 'urumi_email_preview_config';
    const CAPABILITIES_FILE = 'urumi-capabilities.json';

    public static function init() {
        add_action('init', array(__CLASS__, 'register_post_types'));
        add_action('wp_head', array(__CLASS__, 'render_styles'));
        add_action('wp_body_open', array(__CLASS__, 'render_banner'));
        add_action('wp_footer', array(__CLASS__, 'render_popup'), 99);
        add_filter('woocommerce_email_editor_logging_threshold', array(__CLASS__, 'email_logging_threshold'));
        add_filter('woocommerce_email_preview_placeholders', array(__CLASS__, 'email_preview_placeholders'));
        add_filter('woocommerce_email_preview_dummy_address', array(__CLASS__, 'email_preview_dummy_address'));
        add_filter('woocommerce_email_preview_dummy_product', array(__CLASS__, 'email_preview_dummy_product'));
        add_filter('woocommerce_email_preview_dummy_product_variation', array(__CLASS__, 'email_preview_dummy_variation'));
        add_filter('woocommerce_email_preview_dummy_order', array(__CLASS__, 'email_preview_dummy_order'));
    }

    public static function register_post_types() {
        register_post_type('urumi_email_draft', array(
            'labels' => array(
                'name' => 'Urumi Emails',
                'singular_name' => 'Urumi Email Draft',
            ),
            'public' => false,
            'show_ui' => true,
            'show_in_menu' => true,
            'supports' => array('title', 'editor'),
            'menu_icon' => 'dashicons-email-alt',
        ));
    }

    public static function capabilities() {
        $path = plugin_dir_path(__FILE__) . self::CAPABILITIES_FILE;
        if (file_exists($path)) {
            $raw = file_get_contents($path);
            $data = json_decode($raw, true);
            if (is_array($data)) {
                return $data;
            }
        }
        return array(
            'options' => array(
                'woocommerce_email_from_name' => array('type' => 'string'),
                'woocommerce_email_from_address' => array('type' => 'email'),
                self::EMAIL_LOGGING_OPTION => array('type' => 'enum', 'values' => array('DEBUG','INFO','NOTICE','WARNING','ERROR','CRITICAL','ALERT','EMERGENCY')),
                self::EMAIL_PREVIEW_OPTION => array('type' => 'json'),
            ),
            'posts' => array(
                'urumi_email_draft' => array(
                    'fields' => array('title', 'content', 'status'),
                ),
            ),
        );
    }

    public static function email_logging_threshold($threshold) {
        if (!class_exists('WC_Log_Levels')) {
            return $threshold;
        }
        $value = get_option(self::EMAIL_LOGGING_OPTION, '');
        if (!$value) {
            return $threshold;
        }
        $value = strtoupper(trim($value));
        $map = array(
            'EMERGENCY' => WC_Log_Levels::EMERGENCY,
            'ALERT' => WC_Log_Levels::ALERT,
            'CRITICAL' => WC_Log_Levels::CRITICAL,
            'ERROR' => WC_Log_Levels::ERROR,
            'WARNING' => WC_Log_Levels::WARNING,
            'NOTICE' => WC_Log_Levels::NOTICE,
            'INFO' => WC_Log_Levels::INFO,
            'DEBUG' => WC_Log_Levels::DEBUG,
        );
        return isset($map[$value]) ? $map[$value] : $threshold;
    }

    private static function email_preview_config() {
        $raw = get_option(self::EMAIL_PREVIEW_OPTION, '');
        if (!$raw) {
            return array();
        }
        if (is_array($raw)) {
            return $raw;
        }
        $decoded = json_decode($raw, true);
        return is_array($decoded) ? $decoded : array();
    }

    public static function email_preview_placeholders($placeholders) {
        $config = self::email_preview_config();
        $custom = isset($config['placeholders']) && is_array($config['placeholders']) ? $config['placeholders'] : array();
        return array_merge($placeholders, $custom);
    }

    public static function email_preview_dummy_address($address) {
        $config = self::email_preview_config();
        if (!isset($config['address']) || !is_array($config['address'])) {
            return $address;
        }
        foreach ($config['address'] as $key => $value) {
            if (is_scalar($value)) {
                $address[$key] = $value;
            }
        }
        return $address;
    }

    public static function email_preview_dummy_product($product) {
        $config = self::email_preview_config();
        if (isset($config['product_name']) && is_string($config['product_name'])) {
            $product->set_name($config['product_name']);
        }
        return $product;
    }

    public static function email_preview_dummy_variation($variation) {
        $config = self::email_preview_config();
        if (isset($config['variation_name']) && is_string($config['variation_name'])) {
            $variation->set_name($config['variation_name']);
        }
        return $variation;
    }

    public static function email_preview_dummy_order($order) {
        $config = self::email_preview_config();
        if (isset($config['currency']) && is_string($config['currency'])) {
            $order->set_currency($config['currency']);
        }
        return $order;
    }

    public static function render_styles() {
        if (is_admin()) {
            return;
        }
        $banner = get_option(self::BANNER_OPTION, array());
        $popup = get_option(self::POPUP_OPTION, array());
        if (empty($banner['enabled']) && empty($popup['enabled'])) {
            return;
        }
        echo '<style>
.urumi-banner{width:100%;padding:18px 20px;background:linear-gradient(135deg,#1b2838,#2a3d53);color:#fff;display:flex;gap:20px;align-items:center;justify-content:space-between;box-sizing:border-box;flex-wrap:wrap}
.urumi-banner__text{display:flex;flex-direction:column;gap:6px;max-width:720px}
.urumi-banner__title{font-size:20px;font-weight:700;margin:0}
.urumi-banner__subtitle{font-size:14px;opacity:.9;margin:0}
.urumi-banner__cta{display:inline-flex;align-items:center;gap:10px;background:#f7b32b;color:#1a1a1a;padding:10px 16px;border-radius:999px;text-decoration:none;font-weight:600}
.urumi-banner__image{max-width:140px;border-radius:10px;object-fit:cover}
.urumi-popup{position:fixed;inset:0;background:rgba(0,0,0,.55);display:none;align-items:center;justify-content:center;z-index:9999}
.urumi-popup__card{background:#0f141b;border-radius:16px;padding:24px 26px;max-width:420px;color:#f7f4f0;box-shadow:0 20px 50px rgba(0,0,0,.45);text-align:left}
.urumi-popup__title{font-size:20px;font-weight:700;margin:0 0 8px}
.urumi-popup__body{font-size:14px;opacity:.92;margin:0 0 14px}
.urumi-popup__code{display:inline-flex;padding:8px 12px;border-radius:8px;background:#1f2b3a;font-weight:700;letter-spacing:.06em;margin-bottom:14px}
.urumi-popup__cta{display:inline-flex;align-items:center;gap:8px;background:#21c17a;color:#0f141b;padding:8px 14px;border-radius:999px;text-decoration:none;font-weight:600}
.urumi-popup__close{position:absolute;top:14px;right:18px;background:transparent;border:none;color:#fff;font-size:22px;cursor:pointer}
@media (max-width: 640px){
  .urumi-banner{flex-direction:column;align-items:flex-start}
  .urumi-banner__image{max-width:100%}
}
</style>';
    }

    public static function render_banner() {
        if (is_admin()) {
            return;
        }
        $settings = get_option(self::BANNER_OPTION, array());
        if (empty($settings['enabled'])) {
            return;
        }
        $headline = isset($settings['headline']) ? esc_html($settings['headline']) : '';
        $subheadline = isset($settings['subheadline']) ? esc_html($settings['subheadline']) : '';
        $coupon = isset($settings['coupon']) ? esc_html($settings['coupon']) : '';
        $visa = isset($settings['visa_message']) ? esc_html($settings['visa_message']) : '';
        $cta_text = isset($settings['cta_text']) ? esc_html($settings['cta_text']) : 'Shop Now';
        $cta_url = isset($settings['cta_url']) ? esc_url($settings['cta_url']) : home_url('/');
        $image_url = isset($settings['image_url']) ? esc_url($settings['image_url']) : '';

        if ($coupon) {
            $subheadline = trim($subheadline . ' Use code ' . $coupon);
        }
        if ($visa) {
            $subheadline = trim($subheadline . ' ' . $visa);
        }

        echo '<div class="urumi-banner">';
        echo '<div class="urumi-banner__text">';
        if ($headline) {
            echo '<p class="urumi-banner__title">' . $headline . '</p>';
        }
        if ($subheadline) {
            echo '<p class="urumi-banner__subtitle">' . $subheadline . '</p>';
        }
        echo '<a class="urumi-banner__cta" href="' . $cta_url . '">' . $cta_text . '</a>';
        echo '</div>';
        if ($image_url) {
            echo '<img class="urumi-banner__image" src="' . $image_url . '" alt="Offer" />';
        }
        echo '</div>';
    }

    public static function render_popup() {
        if (is_admin()) {
            return;
        }
        $settings = get_option(self::POPUP_OPTION, array());
        if (empty($settings['enabled'])) {
            return;
        }
        $title = isset($settings['title']) ? esc_html($settings['title']) : 'Special Offer';
        $body = isset($settings['message']) ? esc_html($settings['message']) : '';
        $coupon = isset($settings['coupon']) ? esc_html($settings['coupon']) : '';
        $cta_text = isset($settings['cta_text']) ? esc_html($settings['cta_text']) : 'Shop Now';
        $cta_url = isset($settings['cta_url']) ? esc_url($settings['cta_url']) : home_url('/');
        $delay = isset($settings['delay_seconds']) ? max(0, intval($settings['delay_seconds'])) : 5;
        $frequency = isset($settings['frequency_hours']) ? max(1, intval($settings['frequency_hours'])) : 24;

        echo '<div class="urumi-popup" id="urumi-popup">';
        echo '<div class="urumi-popup__card">';
        echo '<button class="urumi-popup__close" type="button" aria-label="Close" onclick="window.UrumiPopupClose && window.UrumiPopupClose()">×</button>';
        echo '<p class="urumi-popup__title">' . $title . '</p>';
        if ($body) {
            echo '<p class="urumi-popup__body">' . $body . '</p>';
        }
        if ($coupon) {
            echo '<div class="urumi-popup__code">' . $coupon . '</div>';
        }
        echo '<a class="urumi-popup__cta" href="' . $cta_url . '">' . $cta_text . '</a>';
        echo '</div>';
        echo '</div>';
        echo '<script>
(function(){
  var popup = document.getElementById("urumi-popup");
  if (!popup) return;
  var key = "urumi_popup_seen";
  var delay = ' . intval($delay) . ' * 1000;
  var frequencyMs = ' . intval($frequency) . ' * 3600 * 1000;
  var last = localStorage.getItem(key);
  if (last && (Date.now() - parseInt(last, 10)) < frequencyMs) return;
  function openPopup(){ popup.style.display = "flex"; }
  function closePopup(){ popup.style.display = "none"; localStorage.setItem(key, String(Date.now())); }
  window.UrumiPopupClose = closePopup;
  popup.addEventListener("click", function(e){ if (e.target === popup) closePopup(); });
  document.addEventListener("keydown", function(e){ if (e.key === "Escape") closePopup(); });
  setTimeout(openPopup, delay);
})();
</script>';
    }
}

Urumi_Campaign_Tools::init();

if (defined('WP_CLI') && WP_CLI) {
    class Urumi_Campaign_CLI {
        private function bool_arg($value, $default = false) {
            if ($value === null) {
                return $default;
            }
            return filter_var($value, FILTER_VALIDATE_BOOLEAN);
        }

        private function output_json($payload) {
            WP_CLI::line(wp_json_encode($payload));
        }

        private function capabilities() {
            return Urumi_Campaign_Tools::capabilities();
        }

        private function option_allowed($key) {
            $caps = $this->capabilities();
            return isset($caps['options']) && isset($caps['options'][$key]);
        }

        private function post_allowed($type) {
            $caps = $this->capabilities();
            return isset($caps['posts']) && isset($caps['posts'][$type]);
        }

        public function capabilities_cmd($args, $assoc_args) {
            $this->output_json(array('ok' => true, 'capabilities' => $this->capabilities()));
        }

        public function option_get($args, $assoc_args) {
            $key = isset($assoc_args['key']) ? sanitize_text_field($assoc_args['key']) : '';
            if (!$key) {
                WP_CLI::error('key is required');
            }
            if (!$this->option_allowed($key)) {
                WP_CLI::error('OPTION_NOT_ALLOWED');
            }
            $value = get_option($key);
            $this->output_json(array('ok' => true, 'key' => $key, 'value' => $value));
        }

        public function option_set($args, $assoc_args) {
            $key = isset($assoc_args['key']) ? sanitize_text_field($assoc_args['key']) : '';
            if (!$key) {
                WP_CLI::error('key is required');
            }
            if (!$this->option_allowed($key)) {
                WP_CLI::error('OPTION_NOT_ALLOWED');
            }
            $value = $assoc_args['value'] ?? null;
            if ($value === null && isset($assoc_args['value_json'])) {
                $value = $assoc_args['value_json'];
            }
            if ($value === null) {
                WP_CLI::error('value is required');
            }
            if (isset($assoc_args['value_json'])) {
                $decoded = json_decode($assoc_args['value_json'], true);
                if (!is_array($decoded) && !is_scalar($decoded)) {
                    WP_CLI::error('value_json must be valid JSON');
                }
                $value = $decoded;
            }
            update_option($key, $value);
            $this->output_json(array('ok' => true, 'key' => $key));
        }

        public function post_create($args, $assoc_args) {
            $post_type = isset($assoc_args['post_type']) ? sanitize_text_field($assoc_args['post_type']) : '';
            if (!$post_type) {
                WP_CLI::error('post_type is required');
            }
            if (!$this->post_allowed($post_type)) {
                WP_CLI::error('POST_TYPE_NOT_ALLOWED');
            }
            $title = isset($assoc_args['title']) ? sanitize_text_field($assoc_args['title']) : '';
            $content = isset($assoc_args['content']) ? wp_kses_post($assoc_args['content']) : '';
            $status = isset($assoc_args['status']) ? sanitize_text_field($assoc_args['status']) : 'draft';
            $post_id = wp_insert_post(array(
                'post_type' => $post_type,
                'post_status' => $status,
                'post_title' => $title,
                'post_content' => $content,
            ), true);
            if (is_wp_error($post_id)) {
                WP_CLI::error($post_id->get_error_message());
            }
            $this->output_json(array('ok' => true, 'post_id' => intval($post_id)));
        }

        public function email_logging_set($args, $assoc_args) {
            $level = isset($assoc_args['level']) ? strtoupper(sanitize_text_field($assoc_args['level'])) : '';
            if (!$level) {
                WP_CLI::error('level is required');
            }
            update_option(Urumi_Campaign_Tools::EMAIL_LOGGING_OPTION, $level);
            $this->output_json(array('ok' => true, 'level' => $level));
        }

        public function email_preview_set($args, $assoc_args) {
            $config_json = $assoc_args['config_json'] ?? '';
            if (!$config_json) {
                WP_CLI::error('config_json is required');
            }
            $decoded = json_decode($config_json, true);
            if (!is_array($decoded)) {
                WP_CLI::error('config_json must be valid JSON object');
            }
            update_option(Urumi_Campaign_Tools::EMAIL_PREVIEW_OPTION, $decoded);
            $this->output_json(array('ok' => true));
        }

        public function banner_create($args, $assoc_args) {
            $headline = isset($assoc_args['headline']) ? sanitize_text_field($assoc_args['headline']) : '';
            $subheadline = isset($assoc_args['subheadline']) ? sanitize_text_field($assoc_args['subheadline']) : '';
            $coupon = isset($assoc_args['coupon']) ? strtoupper(sanitize_text_field($assoc_args['coupon'])) : '';
            $discount = isset($assoc_args['discount']) ? intval($assoc_args['discount']) : 0;
            $visa = isset($assoc_args['visa_message']) ? sanitize_text_field($assoc_args['visa_message']) : '';
            $cta_text = isset($assoc_args['cta_text']) ? sanitize_text_field($assoc_args['cta_text']) : 'Shop Now';
            $cta_url = isset($assoc_args['cta_url']) ? esc_url_raw($assoc_args['cta_url']) : home_url('/');
            $image_url = isset($assoc_args['image_url']) ? esc_url_raw($assoc_args['image_url']) : '';
            $enabled = $this->bool_arg($assoc_args['enabled'] ?? 'true', true);

            if (!$headline) {
                WP_CLI::error('headline is required');
            }
            if ($discount > 0 && $coupon && !$subheadline) {
                $subheadline = $discount . '% off storewide';
            }

            $settings = array(
                'enabled' => $enabled,
                'headline' => $headline,
                'subheadline' => $subheadline,
                'coupon' => $coupon,
                'visa_message' => $visa,
                'cta_text' => $cta_text,
                'cta_url' => $cta_url,
                'image_url' => $image_url,
            );
            update_option(Urumi_Campaign_Tools::BANNER_OPTION, $settings);
            $this->output_json(array('ok' => true, 'banner' => $settings));
        }

        public function popup_create($args, $assoc_args) {
            $title = isset($assoc_args['title']) ? sanitize_text_field($assoc_args['title']) : 'Special Offer';
            $message = isset($assoc_args['message']) ? sanitize_text_field($assoc_args['message']) : '';
            $coupon = isset($assoc_args['coupon']) ? strtoupper(sanitize_text_field($assoc_args['coupon'])) : '';
            $cta_text = isset($assoc_args['cta_text']) ? sanitize_text_field($assoc_args['cta_text']) : 'Shop Now';
            $cta_url = isset($assoc_args['cta_url']) ? esc_url_raw($assoc_args['cta_url']) : home_url('/');
            $delay = isset($assoc_args['delay_seconds']) ? intval($assoc_args['delay_seconds']) : 5;
            $frequency = isset($assoc_args['frequency_hours']) ? intval($assoc_args['frequency_hours']) : 24;
            $enabled = $this->bool_arg($assoc_args['enabled'] ?? 'true', true);

            $settings = array(
                'enabled' => $enabled,
                'title' => $title,
                'message' => $message,
                'coupon' => $coupon,
                'cta_text' => $cta_text,
                'cta_url' => $cta_url,
                'delay_seconds' => max(0, $delay),
                'frequency_hours' => max(1, $frequency),
            );
            update_option(Urumi_Campaign_Tools::POPUP_OPTION, $settings);
            $this->output_json(array('ok' => true, 'popup' => $settings));
        }

        public function email_draft($args, $assoc_args) {
            $subject = isset($assoc_args['subject']) ? sanitize_text_field($assoc_args['subject']) : '';
            $body = isset($assoc_args['body']) ? wp_kses_post($assoc_args['body']) : '';
            if (!$subject || !$body) {
                WP_CLI::error('subject and body are required');
            }
            $post_id = wp_insert_post(array(
                'post_type' => 'urumi_email_draft',
                'post_status' => 'draft',
                'post_title' => $subject,
                'post_content' => $body,
            ), true);
            if (is_wp_error($post_id)) {
                WP_CLI::error($post_id->get_error_message());
            }
            update_post_meta($post_id, '_urumi_managed', 1);
            $this->output_json(array('ok' => true, 'draft_id' => intval($post_id)));
        }

        public function email_send($args, $assoc_args) {
            $confirm = isset($assoc_args['confirm']) ? $assoc_args['confirm'] : '';
            if ($confirm !== 'YES') {
                WP_CLI::error('CONFIRM_REQUIRED');
            }
            $draft_id = isset($assoc_args['draft_id']) ? intval($assoc_args['draft_id']) : 0;
            if ($draft_id <= 0) {
                WP_CLI::error('draft_id is required');
            }
            if (!class_exists('WC_Customer_Query')) {
                WP_CLI::error('WooCommerce not available');
            }
            $limit = isset($assoc_args['limit']) ? intval($assoc_args['limit']) : 20;
            if ($limit < 1) {
                WP_CLI::error('limit must be >= 1');
            }
            if ($limit > 100) {
                WP_CLI::error('limit too high; max 100');
            }
            $subject = get_the_title($draft_id);
            $body = get_post_field('post_content', $draft_id);
            if (!$subject || !$body) {
                WP_CLI::error('Draft not found or empty');
            }
            $query = new WC_Customer_Query(array(
                'limit' => $limit,
                'return' => 'objects',
            ));
            $customers = $query->get_customers();
            $sent = 0;
            foreach ($customers as $customer) {
                $email = $customer->get_email();
                if (!$email) {
                    continue;
                }
                $ok = wp_mail($email, $subject, $body);
                if ($ok) {
                    $sent++;
                }
            }
            $this->output_json(array('ok' => true, 'sent' => $sent, 'limit' => $limit));
        }

        public function status($args, $assoc_args) {
            $banner = get_option(Urumi_Campaign_Tools::BANNER_OPTION, array());
            $popup = get_option(Urumi_Campaign_Tools::POPUP_OPTION, array());
            $this->output_json(array('ok' => true, 'banner' => $banner, 'popup' => $popup));
        }
    }

    $cli = new Urumi_Campaign_CLI();
    WP_CLI::add_command('urumi capabilities', array($cli, 'capabilities_cmd'));
    WP_CLI::add_command('urumi option get', array($cli, 'option_get'));
    WP_CLI::add_command('urumi option set', array($cli, 'option_set'));
    WP_CLI::add_command('urumi post create', array($cli, 'post_create'));
    WP_CLI::add_command('urumi email logging', array($cli, 'email_logging_set'));
    WP_CLI::add_command('urumi email preview', array($cli, 'email_preview_set'));
    WP_CLI::add_command('urumi banner create', array($cli, 'banner_create'));
    WP_CLI::add_command('urumi popup create', array($cli, 'popup_create'));
    WP_CLI::add_command('urumi email draft', array($cli, 'email_draft'));
    WP_CLI::add_command('urumi email send', array($cli, 'email_send'));
    WP_CLI::add_command('urumi status', array($cli, 'status'));
}

<?php
/**
 * Plugin Name: Vesta Shopino Egress Relay (signed, encrypted)
 * Description: Narrow HMAC-authorized forwarding of the owner's Shopino tracking requests from the existing Iran-hosted store.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;

function vesta_shr_b64url_decode($s) {
    if (!is_string($s) || strlen($s) > 30000 || !preg_match('/^[A-Za-z0-9_-]+$/D', $s)) return false;
    return base64_decode(strtr($s, '-_', '+/') . str_repeat('=', (4 - strlen($s) % 4) % 4), true);
}

function vesta_shr_keypair() {
    if (!function_exists('sodium_crypto_box_keypair')) throw new RuntimeException('Shopino encryption not supported.');
    $key = 'vesta_shopino_relay_keypair_v1';
    $stored = get_option($key, '');
    $pair = is_string($stored) ? base64_decode($stored, true) : false;
    if ($pair !== false && strlen($pair) === SODIUM_CRYPTO_BOX_KEYPAIRBYTES) return $pair;
    $fresh = sodium_crypto_box_keypair();
    add_option($key, base64_encode($fresh), '', false);
    $stored = get_option($key, '');
    $pair = is_string($stored) ? base64_decode($stored, true) : false;
    if ($pair === false || strlen($pair) !== SODIUM_CRYPTO_BOX_KEYPAIRBYTES)
        throw new RuntimeException('Cannot initialize Shopino encryption key.');
    return $pair;
}

function vesta_shr_unpack(array $payload) {
    $encoded = isset($payload['sealed']) ? (string) $payload['sealed'] : '';
    $raw = vesta_shr_b64url_decode($encoded);
    if ($raw === false || strlen($raw) < SODIUM_CRYPTO_BOX_SEALBYTES || strlen($raw) > 20000)
        throw new InvalidArgumentException('Invalid encrypted Shopino request.');
    $plain = sodium_crypto_box_seal_open($raw, vesta_shr_keypair());
    if ($plain === false || strlen($plain) > 14000)
        throw new InvalidArgumentException('Shopino encrypted request not valid.');
    $data = json_decode($plain, true);
    if (!is_array($data)) throw new InvalidArgumentException('Invalid Shopino request structure.');
    return $data;
}

function vesta_shr_upstream(array $data) {
    $action = isset($data['action']) ? (string) $data['action'] : '';
    $root = 'https://api.shopino.app/api/v1/shop-panel/shops/7944/order-shippings/';
    $method = 'GET';
    $url = '';
    $body = null;
    $cookie = '';
    $headers = [
        'Accept' => 'application/json',
        'User-Agent' => 'Mozilla/5.0 (OrdersVestaBot; Shopino panel integration)',
        'Origin' => 'https://panel.shopino.app',
        'Referer' => 'https://panel.shopino.app/',
    ];

    if (in_array($action, ['orders_list', 'orders_detail', 'orders_patch'], true)) {
        $session = isset($data['session']) ? trim((string) $data['session']) : '';
        if (!preg_match('/^[A-Za-z0-9._~-]{8,512}$/D', $session))
            throw new InvalidArgumentException('Shopino login is required.');
        $headers['Cookie'] = 'sessionid=' . $session;
        if ($action === 'orders_list') {
            $page = isset($data['page']) ? (int) $data['page'] : 1;
            $size = isset($data['page_size']) ? (int) $data['page_size'] : 20;
            if ($page < 1 || $page > 1000 || $size < 1 || $size > 20)
                throw new InvalidArgumentException('Invalid Shopino pagination.');
            $url = $root . '?page=' . $page . '&page_size=' . $size;
        } else {
            $id = isset($data['id']) ? (int) $data['id'] : 0;
            if ($id <= 0 || $id > 999999999999)
                throw new InvalidArgumentException('Invalid Shopino order id.');
            $url = $root . $id . '/';
            if ($action === 'orders_patch') {
                $code = isset($data['tracking_code']) ? trim((string) $data['tracking_code']) : '';
                $kind = isset($data['type']) ? (string) $data['type'] : 'post';
                if (!preg_match('/^[A-Za-z0-9_-]{6,100}$/D', $code) ||
                    !preg_match('/^[a-z0-9_-]{1,32}$/D', $kind))
                    throw new InvalidArgumentException('Invalid tracking code.');
                $method = 'PATCH';
                $body = wp_json_encode(['tracking_code' => $code, 'type' => $kind]);
            }
        }
    } elseif (in_array($action, ['send_code', 'verify_code'], true)) {
        $phone = isset($data['phone']) ? (string) $data['phone'] : '';
        if (!preg_match('/^09[0-9]{9}$/D', $phone))
            throw new InvalidArgumentException('Invalid phone.');
        $method = 'POST';
        if ($action === 'send_code') {
            $url = 'https://api-go.shopino.app/api/v1/app/send-verification-code/';
            $body = wp_json_encode(['phone' => $phone, 'variant' => 'web', 'resend' => true, 'force_send' => true]);
        } else {
            $code = isset($data['code']) ? (string) $data['code'] : '';
            if (!preg_match('/^[0-9]{4,8}$/D', $code))
                throw new InvalidArgumentException('Invalid verification code.');
            $url = 'https://api.shopino.app/api/v1/app/verify-phone/';
            $body = wp_json_encode(['phone' => $phone, 'code' => $code, 'source' => 'panel']);
        }
    } else {
        throw new InvalidArgumentException('Unsupported Shopino operation.');
    }

    if ($body !== null) $headers['Content-Type'] = 'application/json';
    // Never follow redirects or pass data to arbitrary hosts. The URL is built
    // solely from fixed allowlisted Shopino API origins and paths above.
    $response = wp_remote_request($url, [
        'method' => $method,
        'headers' => $headers,
        'body' => $body,
        'timeout' => 45,
        'redirection' => 0,
        'sslverify' => true,
        'limit_response_size' => 10000000,
    ]);
    if (is_wp_error($response)) throw new RuntimeException('Shopino upstream connection failed.');
    $status = (int) wp_remote_retrieve_response_code($response);
    $raw = (string) wp_remote_retrieve_body($response);
    $ctype = (string) wp_remote_retrieve_header($response, 'content-type');
    if (strlen($raw) > 10000000)
        throw new RuntimeException('Shopino response too large.');
    if ($status === 204 && $action === 'orders_patch') {
        $parsed = ['updated' => true];
    } else {
        $parsed = json_decode($raw, true);
        if (!is_array($parsed)) {
            if (stripos($raw, 'VPN را خاموش کنید') !== false)
                throw new RuntimeException('Shopino blocked the origin connection.');
            throw new RuntimeException('Shopino returned a non-JSON response.');
        }
    }
    $out = ['status_code' => $status, 'body' => $parsed];
    if ($action === 'verify_code' && $status >= 200 && $status < 300) {
        $session = '';
        foreach ((array) wp_remote_retrieve_cookies($response) as $item) {
            if (isset($item->name) && $item->name === 'sessionid') {
                $session = (string) $item->value;
                break;
            }
        }
        if ($session === '') {
            foreach (['sessionid', 'session_id', 'session'] as $field) {
                if (!empty($parsed[$field])) {
                    $session = (string) $parsed[$field];
                    break;
                }
            }
        }
        if ($session !== '' && preg_match('/^[A-Za-z0-9._~-]{8,512}$/D', $session))
            $out['sessionid'] = $session;
    }
    return $out;
}

function vesta_shr_dispatch() {
    if (!isset($_GET['vbb']) || (string) $_GET['vbb'] !== '2' || !isset($_GET['o'])) return;
    $op = sanitize_key(wp_unslash($_GET['o']));
    if ($op !== 'shopino_key' && $op !== 'shopino_call') return;
    if (!function_exists('vbb_v2_authorize')) {
        wp_send_json_error(['message' => 'Signed bridge unavailable.'], 503);
    }
    list($authorized, $payload) = vbb_v2_authorize();
    if ($authorized !== $op) vbb_fail('Invalid Shopino operation.', 400);
    try {
        vbb_no_cache();
        if ($op === 'shopino_key') {
            $key = base64_encode(sodium_crypto_box_publickey(vesta_shr_keypair()));
            wp_send_json_success(['public_key' => $key]);
        }
        wp_send_json_success(vesta_shr_upstream(vesta_shr_unpack($payload)));
    } catch (InvalidArgumentException $e) {
        vbb_fail($e->getMessage(), 400);
    } catch (Throwable $e) {
        // Never expose Shopino session, OTP or upstream private content in errors.
        vbb_fail($e->getMessage(), 502);
    }
    exit;
}
add_action('plugins_loaded', 'vesta_shr_dispatch', PHP_INT_MAX - 10);

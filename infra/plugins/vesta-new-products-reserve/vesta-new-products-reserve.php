<?php
/**
 * Plugin Name: Vesta homepage mobile new-products reservation
 * Description: Reserve first products row space before Woodmart/Owl initialization.
 */
if (!defined('ABSPATH')) exit;
add_action('wp_head', function () {
    if (is_admin() || !is_front_page()) return;
    echo '<style id="vc-vesta-new-products-mobile-reserve">@media(max-width:767px){#nomarg{min-height:405px!important}}</style>'."\n";
}, 1);

<?php
error_reporting(E_ERROR|E_PARSE);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
if(!class_exists('Vesta_Channel_Customers'))exit(20);
echo 'CHANNEL_ACCOUNT_WORKER='.json_encode(Vesta_Channel_Customers::sweep())."\n";

#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== boot WordPress against candidate DB without changing live config ==="
docker exec   -e CANDIDATE_ROOT_PASSWORD="$VESTA_DB_ROOT_PASSWORD"   vc-vesta php -d display_errors=1 -d error_reporting=E_ALL -r '
define("DB_NAME","vestacos_candidate");
define("DB_USER","root");
define("DB_PASSWORD",getenv("CANDIDATE_ROOT_PASSWORD"));
define("DB_HOST","db-vesta");
define("WP_DEBUG",true);
define("WP_DEBUG_DISPLAY",true);
define("WP_DEBUG_LOG",false);
$_SERVER["HTTP_HOST"]="vesta-cosmetics.ir";
$_SERVER["HTTPS"]="on";
$_SERVER["REQUEST_URI"]="/";
$_SERVER["SERVER_NAME"]="vesta-cosmetics.ir";
$_SERVER["SERVER_PORT"]="443";
require "/var/www/html/wp-config.php";
echo "CANDIDATE_WP_BOOT_OK\n";
' 2>&1 | tail -200

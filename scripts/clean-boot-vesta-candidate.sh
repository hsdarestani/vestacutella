#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== clean WordPress boot against candidate DB ==="
docker exec -e VC_DB_PASS="$VESTA_DB_PASSWORD" vc-vesta php -d display_errors=1 -d error_reporting=E_ALL -r '
define("ABSPATH","/var/www/html/");
define("DB_NAME","vestacos_candidate");
define("DB_USER","vestacos_m");
define("DB_PASSWORD",getenv("VC_DB_PASS"));
define("DB_HOST","db-vesta");
define("DB_CHARSET","utf8mb4");
define("DB_COLLATE","");
define("WP_DEBUG",true);
define("WP_DEBUG_DISPLAY",true);
define("WP_DEBUG_LOG",false);
define("WP_ENVIRONMENT_TYPE","staging");
define("DISABLE_WP_CRON",true);
define("WP_MEMORY_LIMIT","512M");
define("WP_MAX_MEMORY_LIMIT","512M");
$table_prefix="wp_";
$_SERVER["HTTP_HOST"]="vesta-cosmetics.ir";
$_SERVER["HTTPS"]="on";
$_SERVER["REQUEST_URI"]="/";
$_SERVER["SERVER_NAME"]="vesta-cosmetics.ir";
$_SERVER["SERVER_PORT"]="443";
require ABSPATH."wp-settings.php";
echo "CANDIDATE_WP_BOOT_OK\n";
' 2>&1 | tail -300

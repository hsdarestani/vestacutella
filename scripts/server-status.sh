#!/usr/bin/env bash
set -u
echo "=== time ==="; date
echo "=== staging/runtime sizes ==="; du -sh /srv/vestacutella/staging /srv/vestacutella/runtime 2>/dev/null || true
echo "=== markers ==="; find /srv/vestacutella -maxdepth 3 -type f \( -name '.extracted' -o -name '.imported' -o -name '.app-passwords-rotated' \) -print 2>/dev/null || true
echo "=== containers ==="; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

echo "=== local HTTPS responses ==="
for domain in cutellashop.ir vesta-cosmetics.ir; do
  echo "--- $domain / ---"
  curl -ksS --resolve "$domain:443:127.0.0.1" -D /tmp/"$domain".headers -o /tmp/"$domain".body "https://$domain/" || true
  head -n 20 /tmp/"$domain".headers || true
  echo "body_bytes=$(wc -c < /tmp/"$domain".body 2>/dev/null || echo 0)"
  head -c 1200 /tmp/"$domain".body 2>/dev/null | tr '\000' ' ' || true
  echo
  echo "--- $domain /wp-login.php ---"
  curl -ksS --resolve "$domain:443:127.0.0.1" -o /dev/null -w 'HTTP=%{http_code} SIZE=%{size_download} REDIRECT=%{redirect_url}\n' "https://$domain/wp-login.php" || true
done

echo "=== recent WordPress container logs ==="
echo "--- Cutella ---"
docker logs --tail 50 vc-cutella 2>&1 || true
echo "--- Vesta ---"
docker logs --tail 80 vc-vesta 2>&1 || true

echo "=== disk ==="; df -h /

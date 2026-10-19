#!/usr/bin/env bash
set -uo pipefail
for host in mail.vesta-cosmetics.ir smtp.vesta-cosmetics.ir server135s.irwebspace.com;do
 for port in 587 465;do
  echo "=== MAIL_TLS host=$host port=$port ==="
  if [[ "$port" == 587 ]];then opt=(-starttls smtp);else opt=();fi
  raw="$(timeout 10 openssl s_client -connect "$host:$port" "${opt[@]}" -servername "$host" -verify_return_error -brief </dev/null 2>&1 || true)"
  printf '%s\n' "$raw" | grep -Ei 'Peer certificate|Verification error|verify error|certificate verify failed|Verification:|Protocol version|Ciphersuite|alert certificate|self.signed|unable to|expired' | head -12 || true
  timeout 10 openssl s_client -connect "$host:$port" "${opt[@]}" -servername "$host" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null | head -7 || true
 done
done
echo CERT_CHAIN_PUBLIC_PROBE_COMPLETE

#!/bin/bash
# Kroky nasazení, které potřebují root: CORS i u chybových odpovědí + restart služby.
set -euo pipefail
conf=/etc/nginx/sites-enabled/default
cp "$conf" "/root/nginx-default.bak-$(date +%Y%m%d-%H%M%S)"
sed -i -E "/add_header/ { / always;$/! s/;$/ always;/ }" "$conf"
nginx -t
systemctl reload nginx
systemctl restart scale
sleep 3
systemctl --no-pager --lines=0 status scale | head -3
curl -sk -w ' [%{http_code}]\n' https://localhost/live -H 'Host: squared-expedice.local'

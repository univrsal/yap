#!/bin/sh
# Writes nginx's config for yap, run by the nginx image's entrypoint (see the
# proxy profile in docker-compose.yml). Until certbot has fetched a certificate
# for YAP_DOMAIN, nginx serves plain HTTP (http.conf.template), and afterwards
# HTTPS (https.conf.template). It checks for the certificate every minute and
# reloads nginx twice a day for the renewed one.
set -eu

if [ -z "${YAP_DOMAIN:-}" ]; then
	echo "yap: set YAP_DOMAIN to the domain the server is reached at" >&2
	exit 1
fi
YAP_RELAY_PORT=${YAP_RELAY_PORT:-8080}
# Where to redirect HTTP to, with the port if it isn't 443.
YAP_HTTPS_HOST='$host'
if [ "${YAP_HTTPS_PORT:-443}" != 443 ]; then
	YAP_HTTPS_HOST="\$host:$YAP_HTTPS_PORT"
fi
# The container's DNS server, so that nginx finds the yap container again
# after it was restarted with another address.
YAP_RESOLVER=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)
case $YAP_RESOLVER in
*:*) YAP_RESOLVER="[$YAP_RESOLVER]" ;;
esac
export YAP_DOMAIN YAP_RELAY_PORT YAP_HTTPS_HOST YAP_RESOLVER

conf=/etc/nginx/conf.d/yap.conf

# yap_conf writes the config for whether there is a certificate, and prints
# which one it wrote if that changed it.
yap_conf() {
	scheme=http
	if [ -f "/etc/letsencrypt/live/$YAP_DOMAIN/fullchain.pem" ]; then
		scheme=https
	fi
	envsubst '${YAP_DOMAIN} ${YAP_RELAY_PORT} ${YAP_HTTPS_HOST} ${YAP_RESOLVER}' \
		<"/etc/nginx/yap/$scheme.conf.template" >"$conf.new"
	if cmp -s "$conf.new" "$conf"; then
		rm "$conf.new"
	else
		mv "$conf.new" "$conf"
		echo "$scheme"
	fi
}

rm -f /etc/nginx/conf.d/default.conf
echo "yap: serving $(yap_conf) for $YAP_DOMAIN"

# This keeps running beside nginx after the entrypoint has started it.
(
	minutes=0
	while sleep 60; do
		minutes=$((minutes + 1))
		scheme=$(yap_conf) || continue
		if [ -n "$scheme" ]; then
			echo "yap: switching to $scheme"
		elif [ $minutes -lt 720 ]; then
			continue
		fi
		minutes=0
		nginx -s reload || true
	done
) &

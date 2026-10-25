#!/bin/sh
# Fetches a Let's Encrypt certificate for YAP_DOMAIN through nginx's port 80
# (see yap.sh) and renews it, checking twice a day. The certbot container of
# the proxy profile in docker-compose.yml runs this.
set -u

if [ -z "${YAP_DOMAIN:-}" ]; then
	echo "yap: set YAP_DOMAIN to the domain the server is reached at" >&2
	exit 1
fi
set -- --webroot -w /var/www/certbot --non-interactive
if [ -n "${YAP_CERT_STAGING:-}" ]; then
	set -- "$@" --staging
fi

trap exit TERM
while :; do
	wait=12h
	if [ -f "/etc/letsencrypt/live/$YAP_DOMAIN/fullchain.pem" ]; then
		certbot renew "$@"
	elif [ -n "${YAP_CERT_EMAIL:-}" ]; then
		certbot certonly "$@" --agree-tos -d "$YAP_DOMAIN" --email "$YAP_CERT_EMAIL" || wait=1h
	else
		certbot certonly "$@" --agree-tos -d "$YAP_DOMAIN" --register-unsafely-without-email || wait=1h
	fi
	sleep $wait &
	wait $!
done

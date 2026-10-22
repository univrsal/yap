## Running a server

```sh
yap-server               # or: yap-server path/to/config.json
```

The first run writes `config.json`. See the comment in
[config.odin](https://github.com/univrsal/yap/blob/master/src/server/config.odin)
for information on the settings. The admin can create more from the client's
Channels window). Next to it, or in the config's `data_dir`, the server keeps
its database (`yap.db`) and a `blobs` folder.

People need an account to get in, and accounts are made by an admin. A
server that has none makes one called `admin` when it starts and writes its
password to the log, once; log in with that, choose a password of your
own, and make the others from the client's settings. The same can be done
without a client:

```sh
yap-server account list
yap-server account add <username>      # prints a first password
yap-server account passwd <username>   # a new one, if it was forgotten
```

### Docker

[scripts/docker-compose.yml](../scripts/docker-compose.yml) runs the server from
`ghcr.io/univrsal/yap`, with its data (and `config.json`) in a volume. Its
settings come from the environment or a `.env` file next to it; see
[scripts/.env.example](../scripts/.env.example).

```sh
cd scripts
cp .env.example .env    # and edit it
docker compose up -d
```

The `account` commands above need the server to be stopped:

```sh
docker compose stop yap
docker compose run --rm --entrypoint yap-server yap account list /data/config.json
docker compose start yap
```

`YAP_PORT`, `YAP_VIDEO_PORT` and `YAP_RELAY_PORT` choose the server's UDP
ports and the web relay's TCP port. They are applied to `config.json` on every
start, and are published as the same ports on the host. Other settings, like
`YAP_RELAY_ENABLED`, are only used when `config.json` is created.

With the `proxy` profile, nginx sits in front of the relay and serves the web
client over HTTPS with a Let's Encrypt certificate, which certbot fetches and
renews. Set `YAP_DOMAIN` to a domain that points at the machine, with port 80
reachable for the certificate, and `YAP_RELAY_ENABLED=true` for a new server
(or `relay.enabled` in `config.json`). nginx serves plain HTTP until the
certificate is there, and switches to HTTPS within a minute after.

```sh
docker compose --profile proxy up -d
```

`YAP_RELAY_HOST_IP=127.0.0.1` then keeps the plain-HTTP relay port off the
network. For the bot API behind it, set `api.behind_proxy` in `config.json`.

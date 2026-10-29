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
yap-server account ban <username> "<reason>"   # "" for none
yap-server account unban <username>
yap-server account bans
```

A ban from the command line is recorded as the owner's. The account is
disabled, its email address can't register again, and its devices are
told the reason when they next connect. Moderators ban (and move,
disconnect and mute people in voice) from the client: right-click
someone, or drag them to another channel. That needs a role (Settings >
Roles) that may "Move people between voice rooms and disconnect them",
"Mute people in voice for everyone" or "Ban and unban people".

### Docker

[docker/docker-compose.yml](../docker/docker-compose.yml) runs the server from
`ghcr.io/univrsal/yap`, with its data (and `config.json`) in a volume. Its
settings come from the environment or a `.env` file next to it; see
[docker/.env.example](../docker/.env.example).

```sh
cd docker
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

## Moving from Mattermost

`yap-server import mattermost` makes a new yap server from a Mattermost one: its
people, channels, direct messages and group messages, history, threads,
reactions, pinned and saved posts, the files attached to posts and the custom
emoji, and who was mentioned in what (@name, @channel). The cards of bots and
webhooks aren't imported yet; the command says so at the end. How it works is in
[design/mattermost-import.md](design/mattermost-import.md).

1. On the Mattermost server, as an admin, export the whole instance (not one
   team: that leaves out the direct messages) and download it:

   ```sh
   mmctl export create --include-archived-channels --include-profile-pictures
   mmctl export download <the export's name>.zip
   unzip <the export's name>.zip -d export
   ```

   Mattermost leaves custom emoji and some reactions out of its exports by
   mistake. `tools/mattermost/extras.py` fetches them through the REST API
   into `export/extras.jsonl`, which the import reads if it is there.
2. Start `yap-server` once so that it makes `config.json`, then stop it. The
   database may be one that was only started, not used (the account that the
   first start made is replaced), and the server has to be stopped during
   the import.
3. See what the import would do, without changing anything:

   ```sh
   yap-server import mattermost export --team <team name> --dry-run
   ```

   A yap server is one community, so one team is chosen. The report lists
   what will be made and, as warnings, everything that has to be changed or
   left out: names yap doesn't accept, people who left the team, groups of
   more than eight, emoji it doesn't know.
4. Import:

   ```sh
   yap-server import mattermost export --team <team name> [--owner <username>]
   ```

   `--owner` is who becomes the server's owner (by default the first system
   admin of the export). The import is one step: if anything goes wrong the
   database is as it was. It prints what it is doing every few seconds, and
   makes `import-report.txt` and `passwords.csv` next to `config.json`.
5. Everyone gets a generated password, and has to choose their own at their
   first login. `passwords.csv` (username, email, password) is what to hand
   them out from. Only you can read it. Delete it when you are done.

Deactivated accounts and guests are made disabled, bots are made as bots (give
them new tokens), and everyone starts where they had read to in Mattermost.

# Example bots

Short bots for the [bot API](../../API.md). Each needs the server's API
address and a token:

```sh
export YAP_URL=http://localhost:8080   # the relay's port
export YAP_TOKEN=yap_...               # Settings > Server > Accounts > Make bot
```

| | |
| --- | --- |
| [echo.py](echo.py) | Python (`requests`, `websockets`): answers `!echo <text>` anywhere, and resumes after a dropped socket. |
| [echo.mjs](echo.mjs) | The same in Node 22 or later, with nothing but `fetch` and `WebSocket`. |
| [roll.py](roll.py) | Python: answers `!roll 2d6` in DMs, showing it's typing first. |
| [persona.py](persona.py) | Python: posts as several names and pictures from one bot (personas). |
| [post.sh](post.sh) | curl: posts a message, with a file if given, from a cron job or CI. |

```sh
pip install requests websockets
python echo.py

node echo.mjs

./post.sh 1 "Build 412 passed" build.log

python persona.py 1 clippy.jpg
```

The smallest bot there is, one line of curl:

```sh
curl -H "Authorization: Bot $YAP_TOKEN" -d '{"content": "Backup done"}' $YAP_URL/api/v1/convs/1/messages
```

## Scripts

`scripts/` has scripts for the client (see [design/scripting.md](design/scripting.md)),
which go in `<config folder>/yap/scripts/` or are pasted in with Settings > Scripts >
Add a script:

- `scripts/showcase.lua` uses everything the Scripts page can show: every kind of
  setting, `/commands`, the filters, notifications, status text and a timer.
- `scripts/webget.lua` makes web requests: `/get <address>` and `/post <address> <text>`.

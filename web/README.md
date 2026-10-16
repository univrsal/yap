The yap client, compiled to WebAssembly for use in browsers.

## Running it

```sh
./build.sh                 # the server and the desktop client
./web/build.sh             # the web client, into web/out (needs emscripten)

bin/yap-server             # writes config.json on first run
```

Turn the relay on in `config.json` and restart the server:

```json
"relay": {
	"enabled": true,
	"port": 8080,
	"web_dir": "web/out"
}
```

Then open <http://localhost:8080/>.

## Screen sharing

Only the web client shares and watches screens: the monitor button next
to mute and deafen shares yours, and a monitor at the end of somebody's
row in the channel list means they're sharing - click it to watch. The
desktop client shows who is sharing but can't watch.

It needs WebCodecs with H.264, and sharing also needs `getDisplayMedia`,
which phones don't have (they can still watch). Like the microphone, both
only work on a secure page: `http://localhost` is fine, anything else
needs HTTPS in front of the relay.

Sharing and watching go over a WebSocket of their own, under `/yap-media/`
(the voice and chat one is under `/yap/`). A proxy in front of the relay
has to pass both on as WebSockets. With only `/yap/`, the page connects
but its media link never comes up, so there is no share button and other
people's screens say "watch in a browser". For nginx:

```nginx
location ~ ^/yap(-media)?/ {
	proxy_pass http://127.0.0.1:8080;
	proxy_http_version 1.1;
	proxy_set_header Upgrade $http_upgrade;
	proxy_set_header Connection "upgrade";
	proxy_read_timeout 1h;
	proxy_send_timeout 1h;
}
```

## The relay

The relay runs on that TCP port, alongside the server; `web_dir` points
it at the web build. When the relay is enabled the server also runs a
very simple websocket server. The browser client connects to the
websocket server because we can't use UDP directly in the browser.

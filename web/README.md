The yap client, compiled to WebAssembly for use in browsers.

## Running it

```sh
./build.sh                 # the server and the desktop client
./web/build.sh             # the web client, into web/out (needs emscripten)

bin/yap-server server.key -relay:8080 -web:./web/out
```

Then open <http://localhost:8080/>. 

`-relay` turns on the relay on that TCP port, alongside the server; `-web`
points it at a web build other than `web/out`. When the relay is enabled
the server also runs a very simple websocket server. The browser client
connects to the websocket server because we can't use UDP directly in the
browser.


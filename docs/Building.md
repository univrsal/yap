# Building

You need a recent [Odin](https://odin-lang.org) (the CI and the Docker image
pin the exact release, see `ODIN_RELEASE` in `.github/workflows/build.yml` and
`docker/Dockerfile`), a C compiler, and CMake for the parts below. The scripts
fetch the third-party sources they need into `.cache` the first time.

| What | How |
| --- | --- |
| Server and client, Linux, macOS, OpenBSD | `./build.sh` (extra arguments go to both Odin builds, e.g. `./build.sh -debug`) |
| Server and client, Windows | `build.bat` from a Visual Studio developer prompt |
| Web client | `web/build.sh` (needs emscripten; see [web/README.md](../web/README.md)) |
| Screen sharing add-on (optional) | `scripts/build/build-video.sh` or `.bat` (see [Screenshare.md](Screenshare.md)) |
| Server in a container | `docker build -f docker/Dockerfile .` (see [Server.md](Server.md)) |

The results are in `bin/` (and `web/out/` for the web client). `build.sh` and
`build.bat` only rebuild the C libraries (miniaudio, RNNoise, SQLite, libwebp,
libopus, ...) when their sources or version files change.

## Where things are

| Folder | Holds |
| --- | --- |
| `src/client` | The client. `conn` is the connection to a server (no UI), `ui_*.odin` the UI, and `richtext`, `video`, `imaging`, `headless` are the pieces that need neither. Platform and audio code have folders of their own. |
| `src/server` | The server: one package with the state (`Server`, `Conn`, the database), and `gate`, `mail`, `webpush` and `curl` for the parts that stand alone. |
| `src/common` | What the client and the server share: the protocol (`proto`), logging, key handling, WebP and GIF. |
| `src/lib` | Libraries only the server side uses: `http`, `gateway` (the bot API) and `lite` (a client without a UI, for bots and the stress tool). |
| `src/gateway`, `src/stress` | The standalone gateway and the load-test tool. |
| `src/video` | The screen sharing library, C++. |
| `web` | The web client's page, glue code and build script. |
| `scripts/build`, `scripts/package` | Fetching and building dependencies, and making the release archives. |
| `docker` | The Dockerfile, the compose file and its nginx configuration. |
| `tools` | Generators and one-off tools (emoji table, sounds, test data). |
| `docs` | Documentation. `docs/design` has the notes on how the larger features were planned. |

Imports use three collections: `common:`, `client:` and `lib:`
(`scripts/build/collections.sh` has the flags). Odin makes a package of a folder, so
`src/client/ui_*.odin` stay together, and the sub-packages next to
`src/server/*.odin` are imported by relative path (`import "gate"`).

## Tests

```
. scripts/build/collections.sh
odin test src/common/proto $collections -vet -strict-style
odin test src/server $collections -vet -strict-style
```

Other packages with tests: `src/client/conn`, `src/client/richtext`,
`src/client/imaging`, `src/client` (the UI), `src/server/mail`. CI runs the
ones that need no libraries.

#!/usr/bin/env python3
"""Smoke test of bin/yap-cli in a pseudo-terminal, against a server of its own.

It starts bin/yap-server (or $YAP_SERVER) in a temporary folder, makes an
account, runs bin/yap-cli in a pty, and checks what a terminal would show:
the login dialog, the channel list, a message sent and read back, the mouse,
a resize, and that Ctrl+C leaves the terminal as it was found.

Usage: scripts/cli-smoke.py          (build with ./build.sh and ./build-cli.sh first)
"""
import fcntl, os, pty, re, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time, unicodedata

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SERVER = os.environ.get("YAP_SERVER", os.path.join(ROOT, "bin", "yap-server"))
CLI = os.environ.get("YAP_CLI", os.path.join(ROOT, "bin", "yap-cli"))
PORT = 18777
PORT2 = 18790


class Screen:
    """Enough of a terminal to read what yap-cli draws: the cursor, clearing,
    printing, wide characters; styles and modes are only recorded."""

    def __init__(self, w, h):
        self.resize(w, h)
        self.raw = ""
        self.alt = False
        self.cursor_visible = True
        self.mouse = False
        self.paste = False

    def resize(self, w, h):
        self.w, self.h = w, h
        self.cells = [[" "] * w for _ in range(h)]
        self.x = self.y = 0

    def rows(self):
        return ["".join(c for c in row).rstrip() for row in self.cells]

    def text(self):
        return "\n".join(self.rows())

    def feed(self, data):
        self.raw += data
        i = 0
        while i < len(data):
            c = data[i]
            if c == "\x1b" and i + 1 < len(data):
                n = data[i + 1]
                if n == "[":
                    m = re.compile(r"[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]").match(data, i + 2)
                    if not m:
                        break
                    self.csi(m.group()[:-1], m.group()[-1])
                    i = m.end()
                    continue
                if n == "]":
                    m = re.compile(r"[^\x07\x1b]*(\x07|\x1b\\)").search(data, i + 2)
                    if not m:
                        break
                    i = m.end()
                    continue
                i += 2
                continue
            if c == "\r":
                self.x = 0
            elif c == "\n":
                self.y = min(self.y + 1, self.h - 1)
            elif ord(c) >= 32:
                w = 2 if unicodedata.east_asian_width(c) in "WF" else 1
                if unicodedata.combining(c):
                    w = 0
                if w and self.x + w <= self.w and self.y < self.h:
                    self.cells[self.y][self.x] = c
                    if w == 2:
                        self.cells[self.y][self.x + 1] = ""
                    self.x += w
            i += 1

    def csi(self, params, final):
        if final == "H":
            parts = (params.split(";") + ["1", "1"])[:2]
            self.y = int(parts[0] or 1) - 1
            self.x = int(parts[1] or 1) - 1
        elif final == "J" and params in ("2", "3"):
            self.cells = [[" "] * self.w for _ in range(self.h)]
        elif final in "hl" and params.startswith("?"):
            on = final == "h"
            for mode in params[1:].split(";"):
                if mode == "1049":
                    self.alt = on
                elif mode == "25":
                    self.cursor_visible = on
                elif mode == "1006":
                    self.mouse = on
                elif mode == "2004":
                    self.paste = on


class Cli:
    def __init__(self, args, size=(100, 30)):
        self.screen = Screen(*size)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execv(CLI, [CLI] + args)
        self.set_size(*size)

    def set_size(self, w, h):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", h, w, 0, 0))
        self.screen.resize(w, h)

    def pump(self, seconds=0.1):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                self.screen.feed(data.decode("utf-8", "replace"))
        return True

    def wait_for(self, text, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.screen.text():
                return True
            if not self.pump(0.1):
                break
        return text in self.screen.text()

    def send(self, data):
        os.write(self.fd, data.encode())

    def exit_status(self, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.05)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        return None


failures = []


def check(ok, what, cli=None):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)
        if cli:
            print("\n".join("      | " + r for r in cli.screen.rows()))


def main():
    for path in (SERVER, CLI):
        if not os.path.exists(path):
            sys.exit(f"{path} is missing: build it first")
    tmp = tempfile.mkdtemp(prefix="yap-cli-smoke-")
    server = None
    try:
        with open(os.path.join(tmp, "config.json"), "w") as f:
            f.write('{"port": %d, "name": "smoke"}' % PORT)
        add = subprocess.run([SERVER, "account", "add", "tester"], cwd=tmp, capture_output=True, text=True)
        m = re.search(r"password: (\S+)", add.stdout)
        if not m:
            sys.exit("could not make an account:\n" + add.stdout + add.stderr)
        password = m.group(1)
        server = subprocess.Popen([SERVER], cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # A second server, to connect to from the client.
        tmp2 = os.path.join(tmp, "second")
        os.makedirs(tmp2)
        with open(os.path.join(tmp2, "config.json"), "w") as f:
            f.write('{"port": %d, "name": "second"}' % PORT2)
        server2 = subprocess.Popen([SERVER], cwd=tmp2, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)

        args = [f"localhost:{PORT}", f"-key:{tmp}/c.key", f"-known-servers:{tmp}/known", f"-log-file:{tmp}/cli.log"]
        cli = Cli(args)
        check(cli.wait_for("Log in"), "asks for a login", cli)
        check(cli.screen.alt and cli.screen.mouse and cli.screen.paste, "uses its own screen, with mouse and paste on")
        cli.send("tester\r")
        cli.pump(0.2)
        cli.send(password + "\r")
        check(cli.wait_for("# Lobby"), "shows the channel after logging in", cli)
        check("tester" in cli.screen.rows()[-1], "names the account in the status bar", cli)

        cli.send("hello from the pty\r")
        check(cli.wait_for("tester hello from the pty"), "sends a message and reads it back", cli)
        check("WARN" not in cli.screen.text() and "INFO" not in cli.screen.text(), "keeps log lines off the screen", cli)
        if os.environ.get("YAP_SMOKE_SHOW"):
            print("\n".join("      | " + r for r in cli.screen.rows()))

        # Completion, a list dialog and copying a drag with the clipboard escape.
        cli.send("/pi")
        check(cli.wait_for("/pins"), "offers commands while typing one", cli)
        cli.send("\x15")  # Ctrl+U clears the line
        cli.pump(0.2)
        cli.send("/pins\r")
        check(cli.wait_for("Pinned messages"), "opens the pinned messages with /pins", cli)
        cli.send("\x1b")
        cli.pump(0.2)
        y = next(i for i, r in enumerate(cli.screen.rows()) if "hello from the pty" in r)
        x = cli.screen.rows()[y].index("hello from")
        start, end = x + 1, x + 5
        before = len(cli.screen.raw)
        cli.send(f"\x1b[<0;{start};{y + 1}M\x1b[<32;{end};{y + 1}M\x1b[<0;{end};{y + 1}m")
        cli.pump(0.4)
        import base64
        m = re.search(r"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07", cli.screen.raw[before:])
        check(m is not None and base64.b64decode(m.group(1)).decode() == "hello", "copies a dragged selection to the clipboard", cli)

        # A click on the channel in the list, and on the message for its menu.
        cli.send("\x1b[<0;5;3M\x1b[<0;5;3m")
        cli.pump(0.3)
        y = next(i for i, r in enumerate(cli.screen.rows()) if "hello from the pty" in r)
        cli.send(f"\x1b[<0;60;{y + 1}M\x1b[<0;60;{y + 1}m")
        check(cli.wait_for("Copy text"), "opens a message's menu with the mouse", cli)
        cli.send("\x1b")
        cli.pump(0.2)
        check("Copy text" not in cli.screen.text(), "closes it with Escape", cli)

        # Resize.
        cli.set_size(70, 20)
        os.kill(cli.pid, signal.SIGWINCH)
        cli.pump(0.5)
        check(cli.screen.rows()[0] != "" and "hello from the pty" in cli.screen.text(), "redraws after a resize", cli)

        # A second server: listed above the channels, switched to with Ctrl+N, and back.
        cli.send(f"/connect localhost:{PORT2}\r")
        check(cli.wait_for("second"), "connects to a second server with /connect", cli)
        check(cli.wait_for("Log in"), "shows the second server (it doesn't know us)", cli)
        rows = cli.screen.rows()
        check(any("localhost:%d" % PORT in r or "smoke" in r for r in rows), "lists both servers", cli)
        cli.send("\x10")  # Ctrl+P
        check(cli.wait_for("hello from the pty"), "goes back to the first with Ctrl+P", cli)

        # Leaving.
        cli.send("\x03")
        status = cli.exit_status()
        check(status == 0, f"leaves on Ctrl+C with status 0 (got {status})")
        tail = cli.screen.raw[-200:]
        check("\x1b[?1049l" in tail and "\x1b[?25h" in tail and "\x1b[?1002l" in tail, "gives the terminal back as it was")

        # A second run is logged in already; SIGTERM leaves cleanly too.
        cli = Cli(args)
        check(cli.wait_for("# Lobby"), "logs in again by itself", cli)
        check("hello from the pty" in cli.screen.text() or cli.wait_for("hello from the pty"), "keeps the history", cli)
        os.kill(cli.pid, signal.SIGTERM)
        status = cli.exit_status()
        check(status == 0 and "\x1b[?1049l" in cli.screen.raw[-200:], f"leaves cleanly on SIGTERM (status {status})")

        # With no server on the command line: the servers joined in the window client,
        # read from its settings and not written back.
        cfg = os.path.join(tmp, "config")
        os.makedirs(os.path.join(cfg, "yap"))
        settings = os.path.join(cfg, "yap", "settings.json")
        with open(settings, "w") as f:
            f.write('{"joined_servers": [{"address": "localhost:%d", "password": "", "channel": ""}]}' % PORT)
        before = open(settings).read()
        scripts = os.path.join(cfg, "yap", "scripts")
        os.makedirs(scripts)
        with open(os.path.join(scripts, "hello.lua"), "w") as f:
            f.write('function get_info() return {name = "Hello", permissions = {"send"}} end\n')
            f.write('yap.register_command("hi", "Say hi", function(ev) yap.send(ev.channel, "hi from the script") end)\n')
        os.environ["XDG_CONFIG_HOME"] = cfg
        cli = Cli(args[1:])
        check(cli.wait_for("# Lobby"), "connects to the joined servers when none is given", cli)
        # A script: switched on with /script, then its command posts a message.
        cli.send("/script on hello.lua\r")
        check(cli.wait_for("hello.lua"), "lists and switches on a script", cli)
        cli.send("\x1b")
        cli.pump(0.3)
        cli.send("/hi\r")
        check(cli.wait_for("hi from the script"), "runs a script's command", cli)
        cli.send("\x03")
        cli.exit_status()
        check(open(settings).read() == before, "leaves the window client's settings as they were")
        shutil.rmtree(scripts)
        del os.environ["XDG_CONFIG_HOME"]

        # Not a terminal: says so.
        r = subprocess.run([CLI] + args, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=10)
        check(r.returncode != 0 and "needs a terminal" in r.stderr, "refuses to run without a terminal")
    finally:
        for srv in (server, locals().get("server2")):
            if srv:
                srv.terminate()
                srv.wait()
        shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        sys.exit(f"{len(failures)} failed")
    print("all passed")


main()

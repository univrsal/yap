#!/usr/bin/env python3
"""Smoke test of bin/yap-cli in a pseudo-terminal, against a server of its own.

It starts bin/yap-server (or $YAP_SERVER) in a temporary folder, makes an
account, runs bin/yap-cli in a pty, and checks what a terminal would show:
the login dialog, the channel list, a message sent and read back, the mouse,
a resize, and that Ctrl+C leaves the terminal as it was found.

On Windows it runs in a pseudo console (ConPTY), which draws the screen again
itself instead of passing everything through: the modes, the clipboard escape and
the alternate screen don't reach this end, so those checks are skipped there.

Usage: scripts/cli-smoke.py          (build with ./build.sh and ./build-cli.sh first,
                                      or build.bat on Windows)
"""
import os, re, shutil, signal, struct, subprocess, sys, tempfile, time, unicodedata

WINDOWS = os.name == "nt"
if WINDOWS:
    import codecs, ctypes, queue, threading
    from ctypes import wintypes
else:
    import fcntl, pty, select, termios

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
EXE = ".exe" if WINDOWS else ""
SERVER = os.environ.get("YAP_SERVER", os.path.join(ROOT, "bin", "yap-server" + EXE))
CLI = os.environ.get("YAP_CLI", os.path.join(ROOT, "bin", "yap-cli" + EXE))
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
        n = int(params) if params.isdigit() else 1
        if final == "H":
            parts = (params.split(";") + ["1", "1"])[:2]
            self.y = min(int(parts[0] or 1) - 1, self.h - 1)
            self.x = min(int(parts[1] or 1) - 1, self.w - 1)
        elif final == "J" and params in ("2", "3"):
            self.cells = [[" "] * self.w for _ in range(self.h)]
        elif final == "J" and params in ("", "0"):
            self.cells[self.y][self.x:] = [" "] * (self.w - self.x)
            for y in range(self.y + 1, self.h):
                self.cells[y] = [" "] * self.w
        elif final == "K" and params in ("", "0"):
            self.cells[self.y][self.x:] = [" "] * (self.w - self.x)
        elif final == "X":
            for x in range(self.x, min(self.x + n, self.w)):
                self.cells[self.y][x] = " "
        elif final == "C":
            self.x = min(self.x + n, self.w - 1)
        elif final == "D":
            self.x = max(self.x - n, 0)
        elif final == "A":
            self.y = max(self.y - n, 0)
        elif final == "B":
            self.y = min(self.y + n, self.h - 1)
        elif final == "G":
            self.x = min(n - 1, self.w - 1)
        elif final == "d":
            self.y = min(n - 1, self.h - 1)
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


class PtyCli:
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

    def resized(self):
        os.kill(self.pid, signal.SIGWINCH)

    def terminate(self):
        os.kill(self.pid, signal.SIGTERM)

    def exit_status(self, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.05)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        return None


# Writes mouse records into the input of the console of the process argv[1]:
# argv[2:] are groups of four, the buttons held, the flags, x and y. It runs in a
# process of its own, as attaching to a console leaves the one it had.
INJECT_MOUSE = r"""
import ctypes, sys
from ctypes import wintypes
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
class MOUSE(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short), ("buttons", wintypes.DWORD),
                ("keys", wintypes.DWORD), ("flags", wintypes.DWORD)]
class EVENT(ctypes.Union):
    _fields_ = [("mouse", MOUSE), ("pad", ctypes.c_byte * 16)]
class RECORD(ctypes.Structure):
    _fields_ = [("type", wintypes.WORD), ("event", EVENT)]
k32.FreeConsole()
if not k32.AttachConsole(int(sys.argv[1])):
    sys.exit("AttachConsole: %d" % ctypes.get_last_error())
k32.CreateFileW.restype = wintypes.HANDLE
h = k32.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
nums = [int(a) for a in sys.argv[2:]]
records = (RECORD * (len(nums) // 4))()
for i in range(len(records)):
    buttons, flags, x, y = nums[i * 4:i * 4 + 4]
    records[i].type = 2  # MOUSE_EVENT
    records[i].event.mouse = MOUSE(x, y, buttons & 0xffffffff, 0, flags)
written = wintypes.DWORD()
k32.WriteConsoleInputW(wintypes.HANDLE(h), records, len(records), ctypes.byref(written))
"""


class ConPtyCli:
    """The same as PtyCli, in a Windows pseudo console. The pseudo console of
    Windows 10 takes no mouse from this end, so the mouse reports that are sent are
    written into the console's input as the records a console window would make."""

    def __init__(self, args, size=(100, 30)):
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.k32 = k32
        HANDLE = wintypes.HANDLE
        DWORD = wintypes.DWORD

        class COORD(ctypes.Structure):
            _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]

        class STARTUPINFOW(ctypes.Structure):
            _fields_ = [("cb", DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                        ("lpTitle", wintypes.LPWSTR), ("dwX", DWORD), ("dwY", DWORD), ("dwXSize", DWORD),
                        ("dwYSize", DWORD), ("dwXCountChars", DWORD), ("dwYCountChars", DWORD),
                        ("dwFillAttribute", DWORD), ("dwFlags", DWORD), ("wShowWindow", wintypes.WORD),
                        ("cbReserved2", wintypes.WORD), ("lpReserved2", ctypes.c_void_p),
                        ("hStdInput", HANDLE), ("hStdOutput", HANDLE), ("hStdError", HANDLE)]

        class STARTUPINFOEXW(ctypes.Structure):
            _fields_ = [("StartupInfo", STARTUPINFOW), ("lpAttributeList", ctypes.c_void_p)]

        class PROCESS_INFORMATION(ctypes.Structure):
            _fields_ = [("hProcess", HANDLE), ("hThread", HANDLE), ("dwProcessId", DWORD), ("dwThreadId", DWORD)]

        self.COORD = COORD
        k32.CreatePseudoConsole.argtypes = [COORD, HANDLE, HANDLE, DWORD, ctypes.POINTER(HANDLE)]
        k32.CreatePseudoConsole.restype = ctypes.c_long
        k32.ResizePseudoConsole.argtypes = [HANDLE, COORD]
        k32.ClosePseudoConsole.argtypes = [HANDLE]
        k32.CreatePipe.argtypes = [ctypes.POINTER(HANDLE), ctypes.POINTER(HANDLE), ctypes.c_void_p, DWORD]
        k32.ReadFile.argtypes = [HANDLE, ctypes.c_void_p, DWORD, ctypes.POINTER(DWORD), ctypes.c_void_p]
        k32.WriteFile.argtypes = [HANDLE, ctypes.c_void_p, DWORD, ctypes.POINTER(DWORD), ctypes.c_void_p]
        k32.CloseHandle.argtypes = [HANDLE]
        k32.InitializeProcThreadAttributeList.argtypes = [ctypes.c_void_p, DWORD, DWORD, ctypes.POINTER(ctypes.c_size_t)]
        k32.UpdateProcThreadAttribute.argtypes = [ctypes.c_void_p, DWORD, ctypes.c_size_t, ctypes.c_void_p,
                                                  ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p]
        k32.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                                       wintypes.BOOL, DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                                       ctypes.c_void_p, ctypes.c_void_p]
        k32.WaitForSingleObject.argtypes = [HANDLE, DWORD]
        k32.GetExitCodeProcess.argtypes = [HANDLE, ctypes.POINTER(DWORD)]

        self.screen = Screen(*size)
        in_read, self.in_write, self.out_read, out_write = HANDLE(), HANDLE(), HANDLE(), HANDLE()
        if not k32.CreatePipe(ctypes.byref(in_read), ctypes.byref(self.in_write), None, 0) or \
           not k32.CreatePipe(ctypes.byref(self.out_read), ctypes.byref(out_write), None, 0):
            raise OSError(ctypes.get_last_error(), "CreatePipe")
        self.hpc = HANDLE()
        hr = k32.CreatePseudoConsole(COORD(*size), in_read, out_write, 0, ctypes.byref(self.hpc))
        if hr != 0:
            raise OSError(hr, "CreatePseudoConsole")
        k32.CloseHandle(in_read)
        k32.CloseHandle(out_write)

        n = ctypes.c_size_t(0)
        k32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(n))
        self.attrs = ctypes.create_string_buffer(n.value)
        if not k32.InitializeProcThreadAttributeList(self.attrs, 1, 0, ctypes.byref(n)):
            raise OSError(ctypes.get_last_error(), "InitializeProcThreadAttributeList")
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
        if not k32.UpdateProcThreadAttribute(self.attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, self.hpc,
                                             ctypes.sizeof(HANDLE), None, None):
            raise OSError(ctypes.get_last_error(), "UpdateProcThreadAttribute")
        si = STARTUPINFOEXW()
        si.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        # Without this a program started from a shell whose output is a pipe
        # writes to that pipe instead of the pseudo console.
        STARTF_USESTDHANDLES = 0x100
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES
        si.lpAttributeList = ctypes.cast(self.attrs, ctypes.c_void_p)
        pi = PROCESS_INFORMATION()
        EXTENDED_STARTUPINFO_PRESENT = 0x00080000
        cmdline = ctypes.create_unicode_buffer(subprocess.list2cmdline([CLI] + args))
        if not k32.CreateProcessW(None, cmdline, None, None, False, EXTENDED_STARTUPINFO_PRESENT,
                                  None, None, ctypes.byref(si), ctypes.byref(pi)):
            raise OSError(ctypes.get_last_error(), "CreateProcessW")
        self.process = pi.hProcess
        self.pid = pi.dwProcessId
        self.buttons = 0
        k32.CloseHandle(pi.hThread)

        # ReadFile on the pipe blocks, so a thread reads and pump takes what it got.
        self.got = queue.Queue()

        def reader():
            buf = ctypes.create_string_buffer(65536)
            read = DWORD()
            while k32.ReadFile(self.out_read, buf, len(buf), ctypes.byref(read), None) and read.value:
                self.got.put(buf.raw[:read.value])
            self.got.put(None)

        threading.Thread(target=reader, daemon=True).start()
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.closed = False

    def set_size(self, w, h):
        self.k32.ResizePseudoConsole(self.hpc, self.COORD(w, h))
        self.screen.resize(w, h)

    def resized(self):
        pass  # the console tells the program itself

    def pump(self, seconds=0.1):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = self.got.get(timeout=0.05)
            except queue.Empty:
                continue
            if data is None:
                return False
            self.screen.feed(self.decoder.decode(data))
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
        at = 0
        for m in re.finditer(r"\x1b\[<(\d+);(\d+);(\d+)([Mm])", data):
            self.write(data[at:m.start()])
            self.mouse(int(m.group(1)), int(m.group(2)) - 1, int(m.group(3)) - 1, m.group(4) == "m")
            at = m.end()
        self.write(data[at:])

    def write(self, data):
        if data:
            b = data.encode()
            written = wintypes.DWORD()
            self.k32.WriteFile(self.in_write, b, len(b), ctypes.byref(written), None)

    def mouse(self, b, x, y, release):
        """Writes an SGR mouse report as a console mouse record."""
        MOUSE_MOVED, MOUSE_WHEELED = 0x1, 0x4
        if b & 64:
            buttons, flags = (120 if b & 1 == 0 else -120) << 16, MOUSE_WHEELED
        else:
            mask = {0: 0x1, 1: 0x4, 2: 0x2}.get(b & 3, 0)
            flags = 0
            if b & 32:
                flags = MOUSE_MOVED
            elif release:
                self.buttons &= ~mask
            else:
                self.buttons |= mask
            buttons = self.buttons
        subprocess.run([sys.executable, "-c", INJECT_MOUSE, str(self.pid), str(buttons), str(flags), str(x), str(y)],
                       creationflags=0x00000008, check=True)  # DETACHED_PROCESS

    def terminate(self):
        # Closing the pseudo console is closing the window: the program gets
        # CTRL_CLOSE_EVENT. ClosePseudoConsole waits for the program, so it runs aside.
        self.closed = True
        threading.Thread(target=self.k32.ClosePseudoConsole, args=(self.hpc,), daemon=True).start()

    def exit_status(self, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.05)
            if self.k32.WaitForSingleObject(self.process, 0) == 0:
                code = wintypes.DWORD()
                self.k32.GetExitCodeProcess(self.process, ctypes.byref(code))
                if not self.closed:
                    self.closed = True
                    self.k32.ClosePseudoConsole(self.hpc)
                return code.value
        return None


Cli = ConPtyCli if WINDOWS else PtyCli


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
        # The client's own files (cli.json, scripts, settings) go in the temporary folder,
        # not in the config folder of whoever runs this.
        os.environ["YAP_CONFIG_HOME"] = os.path.join(tmp, "xdg")
        os.makedirs(os.path.join(tmp, "xdg", "yap"))
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

        args = [f"localhost:{PORT}", f"-key:{tmp}/c.key", f"-known-servers:{tmp}/known", f"-log-file:{tmp}/cli.log", "-tone:440"]
        cli = Cli(args)
        check(cli.wait_for("Log in"), "asks for a login", cli)
        if not WINDOWS:
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

        # The emoji picker: found by name, put in the message.
        cli.send("\x1bOR")  # F3
        check(cli.wait_for("Find"), "opens the emoji picker", cli)
        cli.send("rocket")
        check(cli.wait_for("1 found"), "finds an emoji by its name", cli)
        cli.send("\r")
        check(cli.wait_for("> 🚀"), "puts the emoji in the message", cli)
        cli.send("\x15")  # Ctrl+U
        cli.pump(0.2)

        # Emoji shortcodes complete in the message, unknown commands are told.
        cli.send(":rocke")
        check(cli.wait_for(":rocket:"), "offers emoji for a typed :shortcode", cli)
        cli.send("\t")
        check(cli.wait_for("> 🚀"), "puts the chosen emoji in the message", cli)
        cli.send("\x15")
        cli.pump(0.2)
        cli.send("/bna\r")
        check(cli.wait_for("There is no command /bna"), "says when a command does not exist", cli)

        # Completion, a list dialog and copying a drag with the clipboard escape.
        cli.send("/pi")
        check(cli.wait_for("/pins"), "offers commands while typing one", cli)
        cli.send("\x15")  # Ctrl+U clears the line
        cli.pump(0.2)
        cli.send("/pins\r")
        check(cli.wait_for("Pinned messages"), "opens the pinned messages with /pins", cli)
        cli.send("\x1b")
        cli.pump(0.2)
        # (On Windows the copy goes to the system's clipboard, which is that of
        # whoever runs this, so it is not tried there.)
        if not WINDOWS:
            y = next(i for i, r in enumerate(cli.screen.rows()) if "hello from the pty" in r)
            x = cli.screen.rows()[y].index("hello from")
            start, end = x + 1, x + 5
            before = len(cli.screen.raw)
            cli.send(f"\x1b[<0;{start};{y + 1}M\x1b[<32;{end};{y + 1}M\x1b[<0;{end};{y + 1}m")
            cli.pump(0.4)
            import base64
            m = re.search(r"\x1b\]52;c;([A-Za-z0-9+/=]+)\x07", cli.screen.raw[before:])
            check(m is not None and base64.b64decode(m.group(1)).decode() == "hello", "copies a dragged selection to the clipboard", cli)

        # Voice: join the room, mute, look at the settings, leave. (Without a sound
        # system it has to carry on: the server is still told.)
        cli.send("\x1b[18~")  # F7
        check(cli.wait_for("♪ #Lobby"), "joins the voice room", cli)
        check(cli.wait_for("▸ tester"), "lists who is in the room", cli)
        # (the tone is the microphone, so the level meter in the status bar moves)
        end = time.time() + 6
        while time.time() < end and not any(c in cli.screen.rows()[-1] for c in "▂▃▄▅▆▇█"):
            cli.pump(0.2)
        check(any(c in cli.screen.rows()[-1] for c in "▂▃▄▅▆▇█"), "shows the microphone level while in voice", cli)
        cli.send("\x1b[15~")  # F5
        check(cli.wait_for("muted"), "mutes", cli)
        cli.send("\x1b[20~")  # F9
        check(cli.wait_for("Microphone"), "opens the settings", cli)
        cli.send("\x1b")
        cli.pump(0.3)
        cli.send("\x1b[18~")  # F7 again
        cli.pump(1.0)
        check("▸ tester" not in cli.screen.text(), "leaves the voice room", cli)
        cli.send("\x1b[15~")  # unmute

        # A picture: attached with /attach, fetched back as a preview and drawn in cells.
        import struct, zlib
        def png(w, h):
            rows = b"".join(b"\x00" + b"".join(bytes((x * 255 // w, y * 255 // h, 128)) for x in range(w)) for y in range(h))
            def chunk(t, d):
                return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
            return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
        picture = os.path.join(tmp, "gradient.png")
        with open(picture, "wb") as f:
            f.write(png(40, 20))
        cli.send(f"/attach {picture}\r")
        cli.pump(0.3)
        cli.send("a picture\r")
        check(cli.wait_for("▀"), "draws a picture sent in a message", cli)
        if os.environ.get("YAP_SMOKE_SHOW"):
            print("\n".join("      | " + r for r in cli.screen.rows() if r.strip()))

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
        cli.resized()
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
        # /connect is remembered in cli.json, /disconnect forgets it (and removes it from the list).
        cli_json = os.path.join(tmp, "xdg", "yap", "cli.json")
        check("localhost:%d" % PORT2 in open(cli_json).read(), "remembers a server it connected to")
        cli.send("/disconnect second\r")
        end = time.time() + 6
        while time.time() < end and "● second" in cli.screen.text():
            cli.pump(0.2)
        check("second" not in "\n".join(r[:26] for r in cli.screen.rows()), "leaves a server with /disconnect", cli)
        check("localhost:%d" % PORT2 not in open(cli_json).read(), "forgets it, so it is not connected to again")

        # Leaving.
        cli.send("\x03")
        status = cli.exit_status()
        check(status == 0, f"leaves on Ctrl+C with status 0 (got {status})")
        tail = cli.screen.raw[-200:]
        if not WINDOWS:
            check("\x1b[?1049l" in tail and "\x1b[?25h" in tail and "\x1b[?1002l" in tail, "gives the terminal back as it was")

        # A second run is logged in already; SIGTERM leaves cleanly too.
        cli = Cli(args)
        check(cli.wait_for("# Lobby"), "logs in again by itself", cli)
        check("hello from the pty" in cli.screen.text() or cli.wait_for("hello from the pty"), "keeps the history", cli)
        cli.terminate()
        status = cli.exit_status()
        if WINDOWS:
            check(status == 0, f"leaves cleanly when the console closes (status {status})")
        else:
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
        os.environ["YAP_CONFIG_HOME"] = cfg
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
        os.environ["YAP_CONFIG_HOME"] = os.path.join(tmp, "xdg")

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

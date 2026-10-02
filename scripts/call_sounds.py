#!/usr/bin/env python3
"""
Makes the call sounds (src/client/assets/ring.opus, ringback.opus): synthesized
here, so there's nothing to license. Each is one period of a loop, its silence
included; the client plays it over and over while a call rings.

	ring      a call coming in: two soft bell notes, twice, then quiet
	ringback  our call ringing out: a low two-tone purr, then quiet

Needs ffmpeg with libopus.  Usage: scripts/call_sounds.py
"""
import math, os, struct, subprocess, tempfile, wave

RATE = 48000
ASSETS = os.path.join(os.path.dirname(__file__), "..", "src", "client", "assets")

def bell(freq, length, gain):
	out = []
	for i in range(int(length * RATE)):
		t = i / RATE
		env = min(1.0, t / 0.005) * math.exp(-t * 6.0)
		v = math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 2.01 * t) + 0.12 * math.sin(2 * math.pi * freq * 3.02 * t)
		out.append(v * env * gain / 1.47)
	return out

def silence(length):
	return [0.0] * int(length * RATE)

def mix_at(base, add, at):
	start = int(at * RATE)
	for i, v in enumerate(add):
		if start + i < len(base):
			base[start + i] += v

def ring():
	total = silence(3.2)
	for k, at in enumerate([0.0, 0.18, 0.55, 0.73]):
		mix_at(total, bell(880 if k % 2 == 0 else 1175, 0.9, 0.45), at)
	return total

def ringback():
	total = silence(3.0)
	tone = []
	for i in range(int(1.0 * RATE)):
		t = i / RATE
		env = min(1.0, t / 0.02, (1.0 - t) / 0.02)
		tone.append((math.sin(2 * math.pi * 440 * t) + math.sin(2 * math.pi * 480 * t)) * 0.12 * env)
	mix_at(total, tone, 0.0)
	return total

def write(name, samples):
	with tempfile.TemporaryDirectory() as tmp:
		path = os.path.join(tmp, name + ".wav")
		with wave.open(path, "wb") as w:
			w.setnchannels(1)
			w.setsampwidth(2)
			w.setframerate(RATE)
			w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
		out = os.path.join(ASSETS, name + ".opus")
		subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c:a", "libopus", "-b:a", "48k", out], check=True)
		print(out, os.path.getsize(out), "bytes")

write("ring", ring())
write("ringback", ringback())

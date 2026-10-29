#!/usr/bin/env python3
"""
Exports a Mattermost the way an admin would for an import (the whole
instance, with archived channels and profile pictures) and unpacks it.

	tools/mattermost/export.py <container> <out dir>

<container> runs Mattermost with local mode on. <out dir> gets
import.jsonl and data/, replacing what was there.
"""

import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

# docker, or podman (CONTAINER_ENGINE=podman)
ENGINE = os.environ.get("CONTAINER_ENGINE", "docker")
CONTAINER, OUT = sys.argv[1], Path(sys.argv[2])


def mmctl(*args):
	r = subprocess.run(
		[ENGINE, "exec", CONTAINER, "mmctl", "--local", *args],
		capture_output=True,
		text=True,
	)
	if r.returncode != 0:
		sys.exit(f"mmctl {' '.join(args)}: {r.stdout}{r.stderr}")
	return r.stdout


def jobs():
	out = mmctl("export", "job", "list", "--json")
	# With no jobs, it lists the string "No jobs found".
	listed = json.loads(out[out.index("[") :]) if "[" in out else []
	return [job for job in listed if isinstance(job, dict)]


before = {job["id"] for job in jobs()}
started = time.monotonic()
mmctl("export", "create", "--include-archived-channels", "--include-profile-pictures")
# The zip is listed while the job is still writing it, so wait for the job.
while True:
	time.sleep(1)
	new = [job for job in jobs() if job["id"] not in before]
	if new and new[0]["status"] == "success":
		break
	if new and new[0]["status"] in ("error", "canceled"):
		sys.exit(f"the export failed: {new[0]}")
	if time.monotonic() - started > 600:
		sys.exit("the export didn't finish in 10 minutes")
job = new[0]
name = job["id"] + "_export.zip"
print(f"exported {name} in {time.monotonic() - started:.0f} s: {job['data']}")

# The image has no shell or cat, so the file comes out with docker cp.
mmctl("export", "download", name, "/tmp/yap-export.zip")
zipped = OUT.parent / "yap-export.zip"
subprocess.run([ENGINE, "cp", f"{CONTAINER}:/tmp/yap-export.zip", str(zipped)], check=True, capture_output=True)
data = zipped.read_bytes()
zipped.unlink()

if OUT.exists():
	shutil.rmtree(OUT)
OUT.mkdir(parents=True)
with zipfile.ZipFile(io.BytesIO(data)) as z:
	for info in z.infolist():
		# Paths come from the export; keep them inside OUT.
		if info.is_dir() or info.filename.startswith("/") or re.search(r"(^|/)\.\.(/|$)", info.filename):
			continue
		target = OUT / info.filename
		target.parent.mkdir(parents=True, exist_ok=True)
		target.write_bytes(z.read(info))
print(f"{len(data)} bytes, unpacked to {OUT}")

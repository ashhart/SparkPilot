#!/usr/bin/env python3
"""Exercise real container processes, including descendants and an unrelated live session."""
import os
from pathlib import Path
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
script = (root / "runtime/crates/spark-privd/src/terminal_stop.cjs").read_text()
name = "sparkpilot-terminal-stop-" + uuid.uuid4().hex[:12]
image = os.environ.get("SPARK_TERMINAL_TEST_IMAGE", "node:22-bookworm-slim")
tag, other = str(uuid.uuid4()), str(uuid.uuid4())

def docker(*args):
    return subprocess.check_output(["docker", *args], stderr=subprocess.STDOUT, timeout=60).decode()

try:
    docker("run", "-d", "--name", name, image, "node", "-e", "setInterval(()=>{},1000)")
    for identity in (tag, other):
        docker("exec", "-d", "--env=SPARK_TERMINAL_ID=" + identity, name, "node", "-e",
               "require('child_process').spawn('node',['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});setInterval(()=>{},1000)")
    for _ in range(40):
        before = docker("top", name, "-eo", "pid,comm")
        if before.count("node") == 5:
            break
        time.sleep(0.05)
    assert before.count("node") == 5, before
    for _ in range(2):
        docker("exec", name, "node", "-e", script, "--", "spark-stop", tag)
        after = docker("top", name, "-eo", "pid,stat,comm")
        active = [r for r in after.splitlines()[1:] if "Z" not in r.split()[1]]
        assert len(active) == 3, after
    print("PASS: target parent and child stopped; unrelated session preserved; repeated close succeeds")
finally:
    subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)

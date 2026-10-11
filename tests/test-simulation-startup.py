#!/usr/bin/env python3
"""Load the smoke payload using the simulator's declared startup search path."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / "server/simulation/Dockerfile").read_text()
command = json.loads(source.split("\nCMD ", 1)[1].replace("\\\n", ""))
payload = next(line.split()[1:-1] for line in source.splitlines() if line.startswith("COPY "))
with tempfile.TemporaryDirectory(prefix="emacsos-simulation-startup-") as temporary:
    stage = Path(temporary)
    for name in payload:
        shutil.copyfile(repo / name, stage / name)
    command = [argument.replace("/opt/emacsos", str(stage)) for argument in command]
    # Exercise startup module lookup without opening a listener or its idle loop.
    command = ["(ignore)" if argument == "(server-start)" else argument for argument in command]
    command[-1] = (
        f"(progn (load-file {json.dumps(str(stage / 'chat.el'))}) "
        "(unless (featurep 'emacsos-typography) (kill-emacs 1)))"
    )
    environment = dict(os.environ, HOME=temporary)
    environment.pop("EMACSLOADPATH", None)
    subprocess.run(command, cwd=stage, env=environment, check=True, timeout=10)
print("Simulator startup resolves copied chat dependencies")

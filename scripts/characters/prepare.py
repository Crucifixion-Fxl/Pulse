#!/usr/bin/env python3
"""Fetch pinned model and compatible renderer sources into a disposable work directory."""
import concurrent.futures
import json
from pathlib import Path
import shutil
import sys
import urllib.request

work = Path(sys.argv[1]).resolve()
source = Path(__file__).resolve().parent
work.mkdir(parents=True, exist_ok=True)
for name in ['render.js', 'export.mjs', 'package.json', 'package-lock.json',
             'vite.config.js', 'index.html', 'characters.json']:
    shutil.copy(source / name, work / name)
manifest = json.loads((source / 'characters.json').read_text())
renderer = 'a445358fa19543a95cf851d0f1f532e8f66f719d'
jobs = []
for name in ['SpineMhy.js', 'SpineMhyExt.ts', 'patch.js', 'SkeletonParser42.ts', 'PhysicsConstraint.ts']:
    jobs.append((f'https://raw.githubusercontent.com/Senkin219/Spine-Viewer-Mhy/{renderer}/src/utils/{name}', work / 'src/utils' / name))
jobs.append((f'https://raw.githubusercontent.com/Senkin219/Spine-Viewer-Mhy/{renderer}/LICENSE', work / 'RENDERER-LICENSE'))
for character in manifest['characters']:
    for extension in ['json', 'atlas', 'png']:
        path = character['path'] + '.' + extension
        jobs.append((f"https://raw.githubusercontent.com/Senkin219/GI-Character-Spine/{manifest['revision']}/{path}", work / 'public' / path))

def fetch(job):
    url, destination = job
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=60) as response:
        destination.write_bytes(response.read())

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
    list(executor.map(fetch, jobs))
print(f'Prepared {work}')

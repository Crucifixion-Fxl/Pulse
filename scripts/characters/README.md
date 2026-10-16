# Regenerate daily character loops

These scripts export complete skeleton loops, rather than duplicating GIF frames.
They use the selected right-facing skins, the upstream miHoYo extension/physics
parser, four warm-up cycles, aligned secondary motion, and a fixed bounding box
measured across the entire loop. Visible alpha bounds exclude invisible geometry.
The 128px transparent frames retain the original duration at >=60 samples/sec.

On macOS with Node, Python 3 and Google Chrome installed:

```sh
python3 scripts/characters/prepare.py /tmp/island-character-export
cd /tmp/island-character-export
npm ci --ignore-scripts --no-audit --no-fund
./node_modules/.bin/vite
# In a second terminal, after Vite has finished dependency optimization:
cd /tmp/island-character-export
node export.mjs
```

Only a separate headless Chrome process is used. It never attaches to a user's
browser profile. Output goes to `output/`, including representative poses and
SHA-256 digests. Inspect all seven poses, motion and loop seams before copying
`<id>.png` to `TodoIsland/Resources/runner-<id>.png` and updating the character
entries in `RunnerCharacters.json`. Preserve that manifest's provenance fields.

`characters.json` pins the model revision. `prepare.py` pins the compatible
viewer revision; its source and MIT notice are downloaded only into the temporary
build workspace. Neither that renderer nor a browser runtime ships in the app.
The game artwork is credited separately in `RunnerCharacters-NOTICE.txt`.

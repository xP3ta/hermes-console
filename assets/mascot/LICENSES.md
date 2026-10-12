# Mascot atlases: licences

| File | Source | Licence |
|---|---|---|
| `pixel.webp` | derived from `assets/companions/pixel/spritesheet.webp` | CC0-1.0 |
| `nimbus.webp` | derived from `assets/companions/nimbus/spritesheet.webp` | CC0-1.0 |
| `violet.webp` | derived from `assets/companions/violet/spritesheet.webp` | CC0-1.0 |

The three source sheets are project-owned companion artwork released under
CC0-1.0 (see `ASSET_PROVENANCE.md`, "Local companion sprites", and each
`pet.json`). The full legal code is in `assets/companions/CC0-1.0.txt`.

The atlases are built by `tool/mascot/build_atlas.py`: only the cells the
mascot draws are kept, cropped to one shared cell box and turned into white
bodies with dark eyes, so the app can tint them per profile. No other
artwork is used. Do not add sprites here unless their licence is CC0 and
recorded in this table.

# Asset provenance

This file records the origin, redistribution terms and reproducible SHA-256
digests for artwork maintained by Hermes Console. It does not grant rights in
third-party names or trademarks.

## Console identity

The Console mark (a terracotta «C» with a cursor bar on a graphite rounded
square) was supplied by the project owner as vector artwork and selected as
the app identity for launcher, splash, notifications, store and repository
use. It was not copied from or derived from Nous Research or Hermes Agent
artwork. The owner licenses the files listed below for this repository under
`GPL-3.0-only`.

This statement is limited to copyright permission for the listed files in this
repository. It makes no broader trademark claim and grants no trademark rights.

| File | Role | Source | License | SHA-256 |
|---|---|---|---|---|
| `assets/branding/console_mark.svg` | Editable mark (terracotta) | Owner-supplied vector artwork | GPL-3.0-only | `259d95c15bc2ffc4e4c5aefd9f6f6e4e3986bbcb90e396561847d604a9a5baa2` |
| `assets/branding/console_icon.svg` | Editable app icon (graphite rounded square + mark) | Owner-supplied vector artwork | GPL-3.0-only | `e543e80eb6bdcb38fc19d8a74a1b709fffc37f80cfcba51494ea1b7531905e9f` |
| `assets/branding/console_mark.png` | In-app mark (splash, onboarding) | PNG render of `console_mark.svg` | GPL-3.0-only | `34efb1edb6ac87ebb8d94fa5947d4bdee777cbf0e0edee21bead7a6fd298ac71` |
| `assets/branding/console_icon.png` | In-app app icon (About) | Owner-supplied 512 px render of `console_icon.svg` | GPL-3.0-only | `7401045439e5fb107905b4e331eaa16def54bd8856fe7d77f44862446fde8fc4` |
| `assets/icon/play_store_512.png` | Store/readme rendition of the icon (full-bleed square) | Owner-supplied Play Store render | GPL-3.0-only | `8af00bd7efe9c16c998e3aefd9e65010f9896a4484535acb29bdc6de99a91442` |
| `assets/branding/hermes_console_hero.svg` | Editable repository hero | Project-authored vector composition of the mark and an outlined Inter wordmark | GPL-3.0-only | `19cf1e8e28c2d04f3e57b0e292cfcd7b365cc33df90135a6bc0517169f44923c` |
| `assets/branding/hermes_console_hero.png` | Raster repository hero | PNG render of `hermes_console_hero.svg` | GPL-3.0-only | `fbfada6ff6e3a7a21a0cf9eca106ec1f8b57f495e2cc712be2bddbd6dc02f9ae` |
| `assets/branding/console_banner.png` | README banner (mark and wordmark on the graphite card, rounded corners) | Project-authored composition of `console_mark.svg`, the bundled Inter wordmark and the first-run glow | GPL-3.0-only | `4423bec14eeb6e3964fe310533dfabbcc19f93669225f18d57dcf55b7e5c227b` |

The Android launcher, adaptive-icon, notification and splash resources are
vector drawables transcribed from the mark's SVG geometry plus raster
derivatives for legacy densities and the splash. The complete file-by-file
digest manifest of the raster files is
[`assets/branding/android-launcher-splash.sha256`](assets/branding/android-launcher-splash.sha256).

## Approved public demo screenshots

These screenshots were captured from the isolated Project Aurora demo and
were already approved for the Hermes Console website and store presentation.
They contain only fictional data and are reused here without modification.

| File | Role | License | SHA-256 |
|---|---|---|---|
| `docs/screenshots/1.2.10-9008/chat.png` | Conversations | GPL-3.0-only | `3bd993b41d10995cc36edfe711ab623d25e8145725f243679c5928bcf705e3f5` |
| `docs/screenshots/1.2.10-9008/workspace.png` | Kanban | GPL-3.0-only | `febe6102c50f9a57df801ae92f5da7ac7e26733203f3e857ade5ec1ee1686272` |
| `docs/screenshots/1.2.10-9008/tools.png` | Tools | GPL-3.0-only | `9409c85d0a154ec00a2da8e817e7846cea408c0f0359402fb61e7ceaccd749d9` |
| `docs/screenshots/1.2.10-9008/terminal.png` | Terminal | GPL-3.0-only | `50d787d860c46e775da00991a894766645e1a0bd97aeda45a4fbb832194e48ef` |
| `docs/screenshots/1.2.10-9008/automation.png` | Scheduled tasks | GPL-3.0-only | `e304c7a34f0bc0108b58133d94cc4e2ee1eeec0857e546ea706a3dab4253a754` |
| `docs/screenshots/1.2.10-9008/documents.png` | Documents | GPL-3.0-only | `e40bd6ea818ea6a95b1df355ae33a6d72c0053c4c1ee2d22ec4a01be339f4520` |

## Local companion sprites

Nimbus, Pixel and Violet are project-owned companion artwork released by the
project owner under `CC0-1.0`. They are local Hermes Console assets and were not
downloaded from Petdex or copied from Petdex community submissions. Each
manifest repeats the license declaration. The complete CC0 legal code is in
[`assets/companions/CC0-1.0.txt`](assets/companions/CC0-1.0.txt).

| Companion | File | Provenance | License | SHA-256 |
|---|---|---|---|---|
| Nimbus | `assets/companions/nimbus/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `3c683495dd49d552c8775552d4af73a31a3482403dcb851badb36c09feb71b9b` |
| Nimbus | `assets/companions/nimbus/pet.json` | Project-authored manifest | CC0-1.0 | `058ce99c8e51ace521f70796e27ca865dc249e2bfa2401c244b5646d739cf968` |
| Pixel | `assets/companions/pixel/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `b3ccb5fbc29596e79071e9142d9e1167495c4b5dd6b960ab78e8c0158a7060bf` |
| Pixel | `assets/companions/pixel/pet.json` | Project-authored manifest | CC0-1.0 | `f6d534728b318f6709154e509e15ddadf6a2218faebcaa834085f0afe396dbd2` |
| Violet | `assets/companions/violet/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `163b19c92d285e9b5c54b1d22ae9902a68af532bfd4912df0336e387b7ab918b` |
| Violet | `assets/companions/violet/pet.json` | Project-authored manifest | CC0-1.0 | `8ce3c39e29b9690b0c1a3587d38446efafbdd03fadc81b5f9a395836530d9983` |

The header mascot atlases are derived from these sheets (cells cropped and
turned into white bodies for tinting) and keep their CC0-1.0 licence; see
[`assets/mascot/LICENSES.md`](assets/mascot/LICENSES.md).

| Mascot | File | Provenance | License | SHA-256 |
|---|---|---|---|---|
| Nimbus (header mascot) | `assets/mascot/nimbus.webp` | Derived from the Nimbus companion sheet by `tool/mascot/build_atlas.py` | CC0-1.0 | `e5bf12f45bfc9ad1d852587a5939f50ba5b10304748b7dcf397546a137b9260b` |
| Pixel (header mascot) | `assets/mascot/pixel.webp` | Derived from the Pixel companion sheet by `tool/mascot/build_atlas.py` | CC0-1.0 | `7c7c8d45f9e9f6543de596cd61a97d849f3435a8302a22b52f1f5f29ae31be49` |
| Violet (header mascot) | `assets/mascot/violet.webp` | Derived from the Violet companion sheet by `tool/mascot/build_atlas.py` | CC0-1.0 | `438b2a866bd6aaf7d5363c2ddd9d2b9982d3055c15620f377741bbc305045e7c` |

To verify the canonical files from the repository root:

```bash
sha256sum -c assets/branding/android-launcher-splash.sha256
sha256sum assets/branding/console_mark.svg \
  assets/branding/console_icon.svg \
  assets/branding/console_mark.png \
  assets/branding/console_icon.png \
  assets/icon/play_store_512.png \
  assets/companions/*/pet.json \
  assets/companions/*/spritesheet.webp
```

## Provider logos (model picker and Models)

Models and providers are identified by a small monochrome mark. The path data
in `lib/core/widgets/provider_logo_glyphs.dart` is copied unchanged from
[Simple Icons](https://github.com/simple-icons/simple-icons) release 16.1.0
(npm `simple-icons@16.1.0`, file `icons/<slug>.svg`), which is dedicated to
the public domain under `CC0-1.0` (full text in
[`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt)). Only the vector path is used;
brand colours are not: the app tints every mark with its own theme colours.
Hermes Desktop ships no provider logos (it uses Simple Icons only for MCP
connector glyphs), so nothing is taken from it.

| Provider | Simple Icons slug | License |
|---|---|---|
| Alibaba Cloud | `alibabacloud` | CC0-1.0 |
| Anthropic | `anthropic` | CC0-1.0 |
| Cloudflare | `cloudflare` | CC0-1.0 |
| Google Gemini | `googlegemini` | CC0-1.0 |
| GitHub Copilot | `githubcopilot` | CC0-1.0 |
| Google | `google` | CC0-1.0 |
| Hugging Face | `huggingface` | CC0-1.0 |
| Meta | `meta` | CC0-1.0 |
| MiniMax | `minimax` | CC0-1.0 |
| Mistral AI | `mistralai` | CC0-1.0 |
| NVIDIA | `nvidia` | CC0-1.0 |
| Ollama | `ollama` | CC0-1.0 |
| OpenRouter | `openrouter` | CC0-1.0 |
| Perplexity | `perplexity` | CC0-1.0 |
| Vercel | `vercel` | CC0-1.0 |

Marks missing from Simple Icons come from
[LobeHub Icons](https://github.com/lobehub/lobe-icons), npm
`@lobehub/icons-static-svg@1.95.1` (tag `@lobehub/icons-static-svg@1.95.1`,
commit `49a2130df7bfa5eb1b088261bff20a37e2967789`), released under the MIT License, Copyright (c) 2023 LobeHub
([licence at that commit](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/LICENSE);
full notice in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), text in
[`LICENSES/MIT.txt`](LICENSES/MIT.txt)). Only the monochrome `icons/<file>.svg`
variants are used, never the `-color` ones: the `d` attribute of each `<path>`
is copied unchanged into `lib/core/widgets/provider_logo_glyphs_lobehub.dart`
and filled in the app's theme colour (a test checks each glyph fills the same
as under the source's even-odd rule). For
LM Studio the translucent underlay path is omitted so the mark stays
single-tone.

| Provider | LobeHub Icons file | License | Copyright |
|---|---|---|---|
| OpenAI | [`icons/openai.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/openai.svg) | MIT | Copyright (c) 2023 LobeHub |
| DeepSeek | [`icons/deepseek.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/deepseek.svg) | MIT | Copyright (c) 2023 LobeHub |
| xAI | [`icons/xai.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/xai.svg) | MIT | Copyright (c) 2023 LobeHub |
| Nous Research | [`icons/nousresearch.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/nousresearch.svg) | MIT | Copyright (c) 2023 LobeHub |
| Moonshot AI | [`icons/moonshot.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/moonshot.svg) | MIT | Copyright (c) 2023 LobeHub |
| Z.ai | [`icons/zai.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/zai.svg) | MIT | Copyright (c) 2023 LobeHub |
| Microsoft | [`icons/microsoft.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/microsoft.svg) | MIT | Copyright (c) 2023 LobeHub |
| LM Studio | [`icons/lmstudio.svg`](https://github.com/lobehub/lobe-icons/blob/49a2130df7bfa5eb1b088261bff20a37e2967789/packages/static-svg/icons/lmstudio.svg) | MIT | Copyright (c) 2023 LobeHub |

llama.cpp has no permissively licensed mark in either set, so it, like any
unknown or custom endpoint, is shown as a project-drawn monogram: the first
letter of the provider name in a rounded square.

The names and marks remain trademarks of their respective owners. They are
used only to identify which company makes or serves a model; their use implies
no affiliation or endorsement.

## Link brand glyphs (Artefactos)

In «Artefactos» each link carries the mark of its site, as in Hermes
Desktop's Artifacts view. The host table in
`lib/core/widgets/link_brand_glyphs.dart` is Desktop's `BRAND_ICONS`
(`apps/desktop/src/lib/brand-icon.ts`) unchanged, and each glyph's `d`
attribute is copied unchanged from the package Desktop draws them with,
npm `@icons-pack/react-simple-icons@13.11.1`, which packages
[Simple Icons](https://github.com/simple-icons/simple-icons) release 16.8.0
(npm `simple-icons@16.8.0`), dedicated to the public domain under `CC0-1.0`
(full text in [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt)). The file is
generated by `tool/brand_icons/build_link_brand_glyphs.py`. Only the vector
path is used, tinted with the app's theme colours; brand colours are not.
Marks remain trademarks of their owners and only tell which site a link
opens; nothing is fetched from those sites to draw them.

Simple Icons slugs (166, all `CC0-1.0`): `anthropic`, `archlinux`, `arxiv`, `asana`, `atlassian`, `behance`, `bitbucket`, `blender`, `bluesky`, `bun`, `buymeacoffee`, `circleci`, `claude`, `cloudflare`, `codeberg`, `codecov`, `codesandbox`, `confluence`, `coursera`, `crunchbase`, `cursor`, `datadog`, `debian`, `deno`, `devdotto`, `digitalocean`, `discord`, `django`, `docker`, `dropbox`, `electron`, `eslint`, `excalidraw`, `facebook`, `fastapi`, `figma`, `firebase`, `flask`, `forgejo`, `ghost`, `gitea`, `github`, `gitlab`, `gmail`, `go`, `godotengine`, `goodreads`, `google`, `googledocs`, `googledrive`, `googlegemini`, `googlemaps`, `googlescholar`, `grafana`, `graphql`, `hashnode`, `homebrew`, `huggingface`, `imdb`, `instagram`, `internetarchive`, `itchdotio`, `jenkins`, `jira`, `jupyter`, `kaggle`, `kofi`, `kotlin`, `kubernetes`, `laravel`, `leetcode`, `linear`, `mastodon`, `mdnwebdocs`, `medium`, `miro`, `mistralai`, `mongodb`, `netflix`, `netlify`, `nodedotjs`, `notion`, `npm`, `nvidia`, `obsidian`, `ollama`, `openrouter`, `openstreetmap`, `overleaf`, `patreon`, `paypal`, `perplexity`, `php`, `pinterest`, `pnpm`, `postgresql`, `postman`, `prisma`, `producthunt`, `pypi`, `python`, `pytorch`, `quora`, `railway`, `raspberrypi`, `raycast`, `react`, `readthedocs`, `reddit`, `redis`, `render`, `replicate`, `replit`, `researchgate`, `ruby`, `rubyonrails`, `rust`, `scikitlearn`, `semanticscholar`, `sentry`, `serverfault`, `shopify`, `snyk`, `soundcloud`, `sourcehut`, `spotify`, `stackblitz`, `stackexchange`, `stackoverflow`, `steam`, `storybook`, `stripe`, `substack`, `supabase`, `superuser`, `swift`, `tailwindcss`, `tauri`, `telegram`, `tensorflow`, `threedotjs`, `tiktok`, `tldraw`, `trello`, `turborepo`, `twitch`, `typescript`, `ubuntu`, `udemy`, `unity`, `unsplash`, `vercel`, `vimeo`, `vite`, `warp`, `webflow`, `weightsandbiases`, `wikipedia`, `windsurf`, `wordpress`, `x`, `ycombinator`, `youtube`, `zedindustries`, `zoom`, `zotero`.

## README buttons

The store buttons under the README tagline live in `docs/badges/`; none of them
is packaged in the app.

| File | Source | License |
|---|---|---|
| `docs/badges/google-play-en.png`, `docs/badges/google-play-es.png` | Official Google Play badges, unmodified, from <https://play.google.com/intl/en_us/badges/> | Google Play badge guidelines (`LICENSES/LicenseRef-Google-Play-Badge.txt`); trademark notice in the README footer |
| `docs/badges/obtainium.png` | `assets/graphics/badge_obtainium.png` of <https://github.com/ImranR98/Obtainium> | GPL-3.0-only, as that repository |
| `docs/badges/get-it-on-github.png` and `.svg` | Project-authored button in the same shape as the other two; the GitHub mark is the Simple Icons path (CC0 file), text set in Inter (OFL-1.1) | GPL-3.0-only; the mark remains GitHub's, used only to link to the Releases page |
| `docs/badges/visit-website-en.png`, `docs/badges/visit-website-es.png` and their `.svg` | Project-authored buttons in the same shape; the mark is the project's own `assets/branding/console_mark.svg`, text set in Inter (OFL-1.1) | GPL-3.0-only |

The Ko-fi button in the README is Ko-fi's own image, linked from
`storage.ko-fi.com` and not stored in this repository.

## Chat icons (live chat)

The ten icons of the live chat come from the Generative Icons library
(https://generativeicons.com, LottieFiles), whose catalogue declares the MIT
licence for each icon. Outline style, weight 2, «light» motion. Each source
`.lottie` was rasterised frame by frame at 64 px with lottie-web 5.13.0 (MIT,
build time only) and packed into a lossless WebP strip recoloured white (the
app tints it at paint time). `tool/chat_icons/build_atlas.py` rebuilds the
strips; `assets/chat_icons/SOURCES.json` records the SHA-256 of every source
asset and strip. Licence text and credit: `assets/chat_icons/LICENSE.txt`.

| File | Icon | Source asset (catalogue) | License | SHA-256 |
|---|---|---|---|---|
| `assets/chat_icons/agent-team.webp` | Agent team | `assets/agent-team.lottie` | MIT | `47be6862a5e4ea18f9a15914b24c28023f9fc282d533e97de20438a8d5cb6f97` |
| `assets/chat_icons/check.webp` | Check | `assets/check.lottie` | MIT | `01d75105f3516929c99f871e77a4c41a3f077ac8231d29b7140b31cc9b21deb2` |
| `assets/chat_icons/delegate-task.webp` | Delegate task | `assets/delegate-task.lottie` | MIT | `ae1f65d1d45f10ece288ad03623af9b72bd6150473d8c34f9b77bfc756415cfb` |
| `assets/chat_icons/error.webp` | Error | `assets/error.lottie` | MIT | `d4811cc83471287b948e6e5d9a006d7599956ffc10b99146ac73668009e40522` |
| `assets/chat_icons/parallel-tools.webp` | Parallel tools | `assets/parallel-tools.lottie` | MIT | `e0ea9677a220eb31f0428d9b30625ca7dc516107a3c136230135eeac0c78a179` |
| `assets/chat_icons/queued.webp` | Queued | `assets/queued.lottie` | MIT | `b7225488bd8c7be630c19c6066952216d962d7e5fae17d8923af8aa56f2f6a0a` |
| `assets/chat_icons/reasoning.webp` | Reasoning | `assets/reasoning.lottie` | MIT | `70bf953556b39077fa4738e735f6f459fdb2f98235aa96a2e80eb7218ad6d953` |
| `assets/chat_icons/response-stream.webp` | Response stream | `assets/response-stream.lottie` | MIT | `b53fab9c29cff50773e2f8bdaf01e463bb8580e8cb126ff969ddc09d1008f441` |
| `assets/chat_icons/terminal-agent.webp` | Terminal agent | `assets/terminal-agent.lottie` | MIT | `60739bbb2ba285a61067da612c001b7d7b1ab4f442342d76ef02828acd671e4d` |
| `assets/chat_icons/tool-call.webp` | Tool call | `assets/tool-call.lottie` | MIT | `4d38ea5fb9dbadda5f91977a970c4916042b3b18a18087086492395aa928c715` |

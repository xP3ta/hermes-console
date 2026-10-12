# Features

A tour of what Console does in 1.2.15. The README keeps the short version.

## A chat that shows the work

![A chat while Hermes works](screenshots/1.2.15/chat-live.png)

Reasoning, tools and tasks appear in the conversation the way they do in Hermes
Desktop, in plain words, and fold into one quiet line when the turn ends. A
small island at the top names the profile and tells you, only when needed, that
something wants you.

## Voice

![A voice conversation inside the chat](screenshots/1.2.15/voice.png)

Voice conversations happen inside the chat, with pause and end in the composer,
and dictation fills the message box. Speech can run on the phone, with an
on-device recogniser that is loaded ahead of time, or on your Hermes server.
GPT-Live is available when your server supports it.

## Home

![Console Home in the light theme](screenshots/1.2.15/home-light.png)

Now, Chats, Bots, Rooms, Cron and Tasks, each in three sizes, on a screen that
never scrolls. Now puts what needs you first, then what is running. Plan limits
name the provider they belong to.

## Bots and rooms

![A bot room with several profiles replying](screenshots/1.2.15/room.png)

Every Hermes profile is a bot with its own identity: a pet, an image, or a face
with a colour of your choosing. Talk to one, or to several in a room with
@mentions. Skills, tools and MCP servers are one row each, with a switch per
item.

## Cron and Tasks

![Scheduled Cron jobs](screenshots/1.2.15/cron.png)

See and manage scheduled jobs, and move work across a Kanban board or a list.
Each job and task can be muted from its own notification.

## Models

![The Models screen](screenshots/1.2.15/models.png)

Pick a model for the chat, a profile or a bot from a list, edit the fallback
chain, and remove a provider completely when you are done with it.

## Terminal and files

![The SSH terminal](screenshots/1.2.15/terminal.png)

An SSH terminal, SFTP, inline viewers for PDFs, images and Markdown, and the
files Hermes generates, without leaving the app.

## Notifications and widgets

A running turn gets a live notification with Stop. Approvals can be answered
from it. Launcher widgets (Now, Quick chat, Cron, Bots, Rooms, Tasks and Chats)
resize to show more of the same thing.

## First run

![The first-run screen scanning a setup code](screenshots/1.2.15/first-run-code.png)

The first launch opens with the Console mark drawing itself, then a scan, a
confirmation and Home. A plain-words connection screen explains what is
reachable and what is not.

## More screens

| | | |
|---|---|---|
| ![Tasks list](screenshots/1.2.15/tasks-list.png) | ![Tools hub](screenshots/1.2.15/tools.png) | ![Document viewer](screenshots/1.2.15/documents.png) |
| ![Profile editor](screenshots/1.2.15/profile-editor.png) | ![First-run opening](screenshots/1.2.15/first-run.png) | ![Chat in the light theme](screenshots/1.2.15/chat-light.png) |

The screenshots use a fictional dataset. Screens vary a little by app version
and by what your Hermes server exposes.

## Privacy and security in detail

- **Self-hosted, no account.** Console talks to the Hermes servers you add and to
  nothing of ours: no Console account, no advertising SDK, no analytics SDK.
- **Credentials stay on the phone**, in the Android Keystore through
  `flutter_secure_storage`. The app opts out of Android backups.
- **Plain HTTP is for private networks only.** HTTPS is accepted anywhere; HTTP
  only to loopback, private-network, Tailscale and local names. HTTP to a public
  address is refused before anything is sent.
- **Optional locks:** App Lock with the device's biometrics, and read-only
  connections for a phone that must not change anything.
- **What leaves the phone:** your messages and attachments go to your Hermes
  server, which may send them to the model providers you configured there.
  Optional downloads (pets, voice models) contain none of your data. Scanning a
  code happens on the device.

See the [privacy policy](PRIVACY_POLICY.md) and the
[security policy](SECURITY_POLICY.md). Report vulnerabilities privately as
described in [SECURITY.md](../SECURITY.md), and never put keys, real
conversations or pairing codes in a public issue.

## License and independence

Original source is licensed [GPL-3.0-only](../LICENSE). Portions derived from
`rusty4444/hermes-android` keep their MIT notice. Dependencies, models, fonts and
artwork keep their own terms: see [NOTICE](../NOTICE),
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and
[ASSET_PROVENANCE.md](../ASSET_PROVENANCE.md).

Console ("Hermes Console" on Google Play) is maintained by
[XPeta Lab](https://hermes.xpetalab.dev) as an independent project. It works with
Hermes Agent but is not affiliated with, sponsored by or endorsed by Nous
Research.

# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to
`hola@xpetalab.dev`. Include the affected version, impact, reproduction steps,
and the smallest safe proof of concept. Do not include real API keys, tokens,
private keys, conversation content, or server backups.

Do not open a public issue until the report has been acknowledged and a safe
disclosure plan has been agreed. This project is maintained on a best-effort
basis and does not currently operate a paid bug-bounty program.

## Supported versions

Security fixes target the latest published release and the current default
development branch. Older releases may receive a backport when the impact and
available maintainer time justify it.

## Scope

Reports about Console are in scope. Vulnerabilities in Hermes Agent,
Flutter, Android, or another dependency should also be reported to that
project's security contact; a private heads-up here is welcome when Console is
directly affected.

## Notifications

Console raises its notifications on the device. With the app open they come
from its own connection to the user's Hermes. With the app closed they come
from three sources, all using that same connection: the opt-in background
listening (Settings > Notifications; off by default, the only one that keeps
watching Cron, Kanban and rooms), the turn service (on by default, switchable
in Settings > Notifications, up to 30 minutes while a turn you started runs)
and a bounded check (up to 10 minutes) that announces when that turn finishes.
The last two need no opt-in and do not run under App Lock. Console uses no Firebase, push relay or other third-party
service for notifications. Reports about notification content shown on a
locked device, tap payloads, or actions taken from a notification are in
scope.

The application's security architecture and data-handling rules are documented
in [docs/SECURITY_POLICY.md](docs/SECURITY_POLICY.md).

## Reading the other agents' chats can trigger the server's auto-archive

To show the agent rail and the per-agent counts on the profile strip, the app lists the first page of chats of the user's other profiles on their own server. Hermes runs its idle-session auto-archive (`sessions.auto_archive`, off by default; when on, at most once per 24 h per profile) as a side effect of a list read, so these reads can trigger it for those profiles and open their database for writing, exactly as opening that profile's list would. Since 1.4.0 the profile strip makes the same reads in every non-compact window (an open Fold, a tablet, a phone held on its side), also when no rail is visible, not only with the rail on screen. The reads are limited to one per minute per scope and one at a time, are never made while searching, under App Lock or in the background, and write nothing themselves; the app does not change any server setting. Whoever does not want the auto-archive to run on a read should leave `sessions.auto_archive` off on the server.

## Background work while a turn runs

While a turn (or a subagent it started) is still running and the app goes to the background, the "keep the connection while it works" setting (on by default) holds a short foreground service, at most 30 minutes per departure. During it the app keeps that chat's connection to the user's own Hermes server open, redials it with backoff after a network change and re-attaches the session, and asks the server once in a while (`session.active_list`) whether the turn is still running. Nothing is sent to third parties, nothing of the conversation is logged (the diagnostic traces carry only state names), App Lock prevents the hold, and chats at rest are not reconnected. Without the hold, only the bounded background check (at most 10 minutes) and, if you turned it on, the opt-in background listening report the end of a turn.

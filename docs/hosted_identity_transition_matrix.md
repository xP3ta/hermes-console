# Hosted groups identity and completeness transition matrix

The hosted-send parser/client boundary is request-bound. A client request ID (`C`) is not the
durable event ID. The official durable ID is
`S = "user:" + sha256(UTF-8(C)).hex`. A send attempt owns one immutable
`C`/text/thread tuple for the duration of that invocation. Console performs no
automatic compensation or resend after an ambiguous failure. `groups.send` is
official as of 1.2.11: the completeness gap that retired it in 1.2.10 — the
log API only ever supplying a bounded recent window, never a provable
complete conversation — is closed by `HostedGroupLogPage.loadComplete`
(`TuiGatewayClient.groupLogComplete`), which pages `groups.log` from `seq 0`
until it proves `has_more == false`, to the same completeness standard
`groups.list` already held itself to (see "List completeness" below). Every
production room-log read — initial load, and the readback after
send/rename/stop — goes through this path, so a room's transcript is never
presented, nor a message ever sent against it, without first proving the
complete history is in hand.

| Boundary | Required evidence | Accepted transition | Fail-closed result |
|---|---|---|---|
| Capabilities | Authenticated connection ID, socket generation, official method envelope | Exact current generation supports `groups.send` and `groups.log` | No send or log RPC |
| Send request | Exact room `R`; non-empty `C`; required valid thread; non-blank text at most 65,536 UTF-8 bytes | One request with the attempt's unchanged `C`, text and thread | Local `FormatException`; no request |
| Client → durable identity | `S = user:` plus lowercase SHA-256 hex of UTF-8 `C` | ACK `client_event_id == C` and event `event_id == S` | Reject before log |
| ACK event | Exact `R`, positive sequence, `S`, `message.user`, actor with required `{kind:user,id:desktop}` and only official optional `display_name`/`profile`/`connection_id`, positive authority epoch, payload with exactly `text` and `thread_id`, finite `created_at`, boolean `idempotent` | Complete typed event retaining every official actor field and complete canonical payload | Reject unknown/noncanonical actor fields or missing/unknown/extra payload fields before log |
| Log envelope | Exactly `events`, `cursor`, `latest_seq`, `has_more`, and typed `authority {gateway_id,epoch}` evidence (unknown additive fields are ignored) | `cursor` equals the last event sequence, or `since_seq` for an empty page; `latest_seq >= cursor`; `has_more == (cursor < latest_seq)` | Reject whole page |
| Log sequence grammar | First sequence is `since_seq + 1`; all following sequences are contiguous; event IDs are unique; every event room is `R` | Ordered contiguous page | Reject whole page; never sort or repair |
| Room authority | Page authority epoch is at least every page event epoch and at least the ACK event epoch | Rotation from ACK epoch `E` to log epoch `LE >= E` is valid | Reject stale page authority |
| ACK → log proof | Exactly one log event is immutable-equal to the ACK on room, sequence, durable ID, kind, the complete canonical actor (including presence and exact value of `display_name`, `profile`, and `connection_id`), authority epoch, the complete canonical payload, and `created_at`; JSON object key order is not semantic | ACK/log `idempotent` may differ | Reject zero or multiple matches, including any retained actor metadata or payload mutation |
| Exact socket lease | Same connected WebSocket object and generation immediately before and after every awaited `groups.*` request/readback, including a queued transport-close turn | One coherent channel lease from capability proof through terminal readback | Surface connection-lost/unproven state; never rebase a mutation readback or report delivery |
| Visible projection | `publicText` only | Public message text | IDs, actor, authority, timestamps, idempotency and thread stay out of text/tooltip/Semantics trees |

## List completeness

`groups.list` requests the official maximum window (`limit: 500`) and follows
the server's `next_offset` until, and only until, it is `null`. Each continuation
must advance by exactly the number of typed rows returned. Non-advancing,
skipped, reordered, cyclic, malformed, or over-512-page continuations reject the
entire load. Room IDs must be unique across all pages. The client accumulates
privately and returns one immutable ordered list only after the terminal page;
the repository and UI therefore cannot receive an intermediate prefix.

## Log completeness

`HostedGroupLogPage.loadComplete` (`TuiGatewayClient.groupLogComplete`) holds
`groups.log` to the same standard: it pages from `since_seq: 0` and follows
each page's own `cursor` until a page proves `has_more == false`. Each page's
internal grammar is verified by `HostedGroupLogPage.fromJson` (contiguous
sequences, unique event IDs); the loader additionally rejects a non-advancing
continuation, a duplicate event ID across pages, or the room's authority
rotating mid-load (a rotation invalidates every page already read under the
old epoch — restarting the whole load is the only safe move, not continuing
under the new one). This is the production path for every hosted-room log
read: the initial workspace open, and the readback after send, rename, or
stop. A room's transcript and composer only ever render once this proof
exists — see `_HostedRoomWorkspace` in `mission_control_screen.dart`, gated
on `capabilities.supports(GroupMethod.send)`.

## Complete `groups.*` request audit

All enabled official request paths are lease-bound: `groups.capabilities`,
`groups.list`, `groups.state`, `groups.create`, `groups.rename`,
`groups.log`, `groups.send`, `groups.disband`, `groups.stop`, and
`groups.approve`. Create/rename/stop/approve/disband use the mutation's
captured lease for their nested `groups.state` readback; send additionally
reads back `groups.log` on the same lease to prove its ACK landed (see "ACK →
log proof" above). No nested readback calls `connect()` or captures a
replacement channel. `groups.promote` remains non-official. Console retires
server-advertised `groups.retry`: the public action lacks revision, log
position, deferred-event identity, and execution-generation binding, so a
stale action could target a newer task incarnation. `retry` and `promote` are
rejected before any WebSocket frame is sent.

## Message-send retry cases

| Case | Result |
|---|---|
| Exact same `C`, text and thread | May return an idempotent ACK; it is accepted only after the same immutable durable event is proven in the log |
| Same `C`, different text or thread | Conflict/failure; the earlier durable identity cannot prove the new payload |
| Different `C`, same payload | Distinct durable IDs and distinct attempts |
| ACK or log generation rotation | Ambiguous failure; input remains user-owned and Console makes no automatic retry claim |

## Upstream limits

The current upstream protocol has no `expected_authority_epoch` compare-and-swap
field on send and does not carry `client_event_id` in the durable log event.
The boundary validates the deterministic `C → S` mapping and complete
ACK/log tuple but cannot invent stronger authority or retry evidence — that
is why `groups.retry` stays retired even though `groups.send` is now official.
Complete conversation pagination, the other upstream gap this boundary used
to hit, is closed client-side by log completeness (above): the server's
`groups.log` window is still bounded, but the client never treats a bounded
window as the whole story.

Executable coverage lives in `test/hosted_group_send_boundary_test.dart` and
`test/hosted_group_completeness_boundary_test.dart`, with adjacent
DTO/wire/repository/UI/privacy coverage in
`test/hosted_groups_v13_test.dart` and
`test/mission_control_hosted_groups_test.dart`.

## Event parser entry-point audit

Every production log event decode reaches the same grammar in
`HostedGroupEvent.fromJson`. The official `groups.send` client decodes its
ACK there, and `HostedGroupLogPage.fromJson` maps every `groups.log` row
through it, whether read as a single page (`groupLog`) or accumulated to
completeness (`groupLogComplete`) — both share the same generation-fenced
`_groupLogOnLease` path. No alternate actor/payload decoder or map-level
ACK/log equality path exists.

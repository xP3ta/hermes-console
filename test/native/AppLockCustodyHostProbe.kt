// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only
package com.hermesagent.hermes_android

import android.content.Context
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/** Host probe of the actual inbox object, extracted verbatim by the runner.
 * Android Context/preferences are filesystem-backed test seams; this is not
 * Android instrumentation, Keystore validation, or a remote-send E2E.
 */
object AppLockCustodyHostProbe {
    private const val KEY = "pending_actions_v2"
    private fun seed(ctx: Context, age: Long = 0, claimedAge: Long? = null) {
        val now = System.currentTimeMillis()
        val row = JSONObject().put("uid", "synthetic-uid")
            .put("action", "reply").put("payload", "{\"route\":\"room\"}")
            .put("route", "room").put("notificationId", 1)
            .put("source", "widget").put("at", now - age)
            .put("claimedAt", claimedAge?.let { now - it } ?: 0L)
        ctx.getSharedPreferences("hermes_rich_notifications", 0).edit()
            .putString(KEY, JSONArray().put(row).toString()).commit()
    }
    private fun rows(ctx: Context): JSONArray {
        val file = File(ctx.filesDir, "notification_action_inbox_v2.json")
        return JSONArray(if (file.exists()) file.readText() else
            ctx.getSharedPreferences("hermes_rich_notifications", 0).getString(KEY, "[]"))
    }
    private fun storeRows(ctx: Context, all: JSONArray) {
        val file = File(ctx.filesDir, "notification_action_inbox_v2.json")
        if (file.exists()) file.writeText(all.toString())
        else ctx.getSharedPreferences("hermes_rich_notifications", 0).edit()
            .putString(KEY, all.toString()).commit()
    }
    private fun enqueue(ctx: Context): String = HermesNotificationActionInbox.enqueue(
        ctx, "approve", "{\"route\":\"room\"}", null, 1, null, "widget")

    @JvmStatic fun main(args: Array<String>) {
        val ctx = Context(File(args[1]))
        when (args[0]) {
            "seed" -> seed(ctx)
            "take" -> println(JSONArray(HermesNotificationActionInbox.take(ctx, setOf("room"))))
            "take-and-die" -> {
                println(JSONArray(HermesNotificationActionInbox.take(ctx, setOf("room"))))
                System.out.flush()
                Runtime.getRuntime().halt(23)
            }
            "expire-lease" -> {
                val all = rows(ctx)
                all.getJSONObject(0).put("claimedAt", System.currentTimeMillis() - 181_000L)
                storeRows(ctx, all)
            }
            "current-lease-control" -> {
                seed(ctx)
                val first = HermesNotificationActionInbox.take(ctx, setOf("room"))
                val second = HermesNotificationActionInbox.take(ctx, setOf("room"))
                check(first.size == 1 && second.isEmpty()) {
                    "a current lease must suppress a same-process second claim"
                }
            }
            "fresh-claim-control" -> {
                seed(ctx)
                val claim = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                check(claim["uid"] == "synthetic-uid" && claim["reclaimed"] == false)
                check(rows(ctx).singleJSONObject().getLong("claimedAt") > 0)
            }
            "claim-ticket" -> {
                seed(ctx)
                val claim = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                check((claim["claimToken"] as? String)?.isNotBlank() == true) {
                    "claim admission must return an opaque issuer-bound token; actual keys=${claim.keys}"
                }
            }
            "legacy-ack" -> {
                seed(ctx, claimedAge = 181_000L)
                val successor = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                HermesNotificationActionInbox.ack(ctx, setOf("synthetic-uid"))
                check(rows(ctx).length() == 1) {
                    "uid-only predecessor ACK erased successor claim: $successor"
                }
            }
            "capacity" -> {
                val first = enqueue(ctx)
                repeat(32) { enqueue(ctx) }
                val all = rows(ctx)
                check((0 until all.length()).any { all.getJSONObject(it).getString("uid") == first }) {
                    "active capacity pressure evicted the first unexecuted action"
                }
            }
            "rescue-retention" -> {
                seed(ctx, age = 86_400_001L)
                val all = rows(ctx)
                all.getJSONObject(0).put("phase", "rescue_pending")
                    .put("enc", "SYNTHETIC_CIPHERTEXT_NOT_DECRYPTED_BY_THIS_TEST")
                storeRows(ctx, all)
                enqueue(ctx)
                check((0 until rows(ctx).length()).any {
                    rows(ctx).getJSONObject(it).getString("uid") == "synthetic-uid"
                }) { "hard TTL deleted encrypted rescue-pending custody before confirmed rescue" }
            }
            "confirmed-recovery" -> {
                seed(ctx, claimedAge = 181_000L)
                val all = rows(ctx)
                all.getJSONObject(0).put("phase", "confirmed")
                storeRows(ctx, all)
                val claim = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                check(claim["phase"] == "confirmed") {
                    "durable confirmed send is re-delivered without its phase; cannot suppress resend: $claim"
                }
            }
            "phase-real" -> {
                seed(ctx)
                val claim = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                val token = claim["claimToken"] as String
                check(!HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", "wrong", "prepared", "executing"))
                check(HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", token, "prepared", "executing"))
                check(HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", token, "executing", "rescue_pending"))
                check(!HermesNotificationActionInbox.ackClaim(ctx, "synthetic-uid", token))
                val all = rows(ctx)
                all.getJSONObject(0).put("claimedAt", System.currentTimeMillis() - 181_000L)
                storeRows(ctx, all)
                val next = HermesNotificationActionInbox.take(Context(File(args[1])), setOf("room")).single()
                val successor = next["claimToken"] as String
                check(next["phase"] == "rescue_pending" && successor != token)
                check(!HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", token, "rescue_pending", "rescued"))
                check(!HermesNotificationActionInbox.ackClaim(ctx, "synthetic-uid", token))
                check(HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", successor, "rescue_pending", "rescued"))
                check(HermesNotificationActionInbox.ackClaim(ctx, "synthetic-uid", successor))
                check(rows(ctx).length() == 0)
            }
            "confirmed-and-die" -> {
                val claim = HermesNotificationActionInbox.take(ctx, setOf("room")).single()
                val token = claim["claimToken"] as String
                check(HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", token, "prepared", "executing"))
                check(HermesNotificationActionInbox.checkpoint(ctx, "synthetic-uid", token, "executing", "confirmed"))
                println(JSONArray(listOf(claim)))
                System.out.flush()
                Runtime.getRuntime().halt(23)
            }
            else -> error("unknown probe")
        }
    }
    private fun JSONArray.singleJSONObject(): JSONObject {
        check(length() == 1)
        return getJSONObject(0)
    }
}

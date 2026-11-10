package com.hermesagent.hermes_android

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Turn-bounded keep-alive (1.4.0): while a turn the user started is running
 * and the user leaves the app, this short dataSync service keeps the process
 * out of the cached/frozen state, so the app's existing socket to the user's
 * own server keeps receiving the turn and its live row stays current.
 *
 * Reference: Hermes Desktop holds its own resources only while a turn is in
 * flight (apps/desktop/electron/power-save.ts `DEFAULT_KEEP_AWAKE_MODE =
 * 'while-working'`; electron/stream-throttle.ts unthrottles hidden chat
 * windows while any turn runs and re-throttles 5 s after the last one).
 *
 * Unlike the listener removed on 3 Nov this service never polls, never starts
 * at boot, never restarts itself (START_NOT_STICKY, stopWithTask), is started
 * only by the visible app right after it leaves the foreground, and stops
 * when the turn ends, when the app comes back, on the system timeout, or at a
 * native backstop of the cap Dart passes (+1 min).
 *
 * One card (Pixel 9980, Android 16: a group summary with one child was drawn
 * as a second card): the service card IS the chat's live row. A service
 * notification has no tag (`startForeground(id, notification)`, the id "as
 * per NotificationManager.notify(int, Notification)"), the row lives at
 * (`hermes.chat.<id>`, 2), so while the service holds the row is drawn at the
 * service's id ([carry]) and kept out of the tray under its own tag; Dart
 * still posts and cancels it at its own address. With no chat row (replies
 * off, only subagents left, the grace after the end) the card is the
 * service's own copy, which names no chat. When the service stops, the row
 * it carried goes back under its tag first, unless Dart just took it down.
 */
class HermesTurnKeepAliveService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val backstop = Runnable { endFromNative(this, "cap") }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Nothing here may take the app down: a refused or failed start only
        // means Dart does not hold and the background check carries on.
        try {
            // startForeground first, unconditionally: a service started with
            // startForegroundService that returns without it crashes the app.
            val promoted = promote(intent)
            startPending = false
            if (!promoted || intent?.action != ACTION_START || stopRequested) {
                stopRequested = false
                stopNow()
                return START_NOT_STICKY
            }
            running = true
            handler.removeCallbacks(backstop)
            val capMs = (intent?.getLongExtra(EXTRA_CAP_MS, DEFAULT_CAP_MS) ?: DEFAULT_CAP_MS)
                .coerceIn(MIN_CAP_MS, MAX_CAP_MS)
            handler.postDelayed(backstop, capMs + BACKSTOP_SLACK_MS)
            Log.i(TAG, "TurnKeepAlive start")
        } catch (_: Exception) {
            Log.w(TAG, "TurnKeepAlive failed")
            startPending = false
            stopRequested = false
            running = false
            notifyEnded("refused")
            stopNow()
        }
        return START_NOT_STICKY
    }

    private fun promote(intent: Intent?): Boolean {
        return try {
            appContext = applicationContext
            val own = ownCardFor(intent)
            ownCard = own
            // The chat row already in the tray becomes the card (unless this
            // start is to stop at once, or a card is already carried).
            val row =
                if (intent?.action == ACTION_START && !stopRequested && carriedRow == null) {
                    adoptableRow(this)
                } else {
                    null
                }
            startForegroundCompat(serviceCard(this, carriedRow ?: row?.notification ?: own))
            // Only once Android accepted the card does the row leave its tag:
            // a refused start leaves the row where it was.
            if (row != null) takeIntoCard(this, row)
            true
        } catch (_: Exception) {
            // ForegroundServiceStartNotAllowedException (start grace over),
            // the Android 15 dataSync budget spent, SecurityException, or a
            // notification that could not be built. A minimal promotion still
            // answers startForegroundService (its missing call is a crash);
            // the service then stops at once.
            //
            // Known limit (REVISION-3 #9, not verified on a device): the
            // fallback uses the same dataSync type, the only one the manifest
            // declares for this service (another type would throw
            // IllegalArgumentException), so when the refusal is the type's
            // (budget spent, not allowed) it fails the same way. Then
            // stopNow() runs with no successful startForeground. Whether
            // Android reports that as "did not then call startForeground" is
            // not established here; it would be the start-refused variant of
            // RECETA-FGS.md that settles it. Nothing is claimed beyond that:
            // the second failure is logged apart so the recipe can tell the
            // two cases.
            Log.w(TAG, "TurnKeepAlive refused")
            try {
                startForegroundCompat(
                    NotificationCompat.Builder(this, HermesRichNotifications.CH_LIVE)
                        .setSmallIcon(R.drawable.ic_stat_hermes)
                        .setSilent(true)
                        .build(),
                )
            } catch (_: Exception) {
                Log.w(TAG, "TurnKeepAlive refused: fallback promotion failed too")
            }
            notifyEnded("refused")
            false
        }
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** The card when no chat row is carried: it names no chat. */
    private fun ownCardFor(intent: Intent?): Notification {
        HermesRichNotifications.ensureChannels(this)
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: getString(R.string.rich_brand)
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        return NotificationCompat.Builder(this, HermesRichNotifications.CH_LIVE)
                .setSmallIcon(R.drawable.ic_stat_hermes)
                .setColor(HermesRichNotifications.WORKING)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(openAppIntent())
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setSilent(true)
                .build()
    }

    override fun onDestroy() {
        handler.removeCallbacks(backstop)
        running = false
        startPending = false
        putBackCarriedRow(this)
        try {
            stopForegroundCompat()
        } catch (_: Exception) {
        }
        Log.i(TAG, "TurnKeepAlive stop")
        super.onDestroy()
    }

    // The system's dataSync timeout (Android 15 budget): stop within its
    // few seconds whatever happens, never crash.
    override fun onTimeout(startId: Int) {
        endFromNative(this, "timeout")
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        endFromNative(this, "timeout")
    }

    private fun openAppIntent(): PendingIntent {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
        return PendingIntent.getActivity(this, NOTIFICATION_ID, launch, flags)
    }

    private fun stopNow() {
        running = false
        // The row goes back under its tag before the card goes with the
        // service: a running turn is never left without its row.
        putBackCarriedRow(this)
        try {
            stopForegroundCompat()
        } catch (_: Exception) {
        }
        try {
            stopSelf()
        } catch (_: Exception) {
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    companion object {
        private const val TAG = "TurnKeepAlive"
        private const val ACTION_START =
            "dev.xpetalab.hermesconsole.action.START_TURN_KEEPALIVE"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_CAP_MS = "capMs"
        const val NOTIFICATION_ID = 258

        /** The id of a chat's live row (Dart `RichNotificationIds.live`). */
        const val LIVE_ROW_ID = 2
        private const val DEFAULT_CAP_MS = 30 * 60 * 1000L
        private const val MIN_CAP_MS = 60 * 1000L
        private const val MAX_CAP_MS = 2 * 60 * 60 * 1000L
        private const val BACKSTOP_SLACK_MS = 60 * 1000L

        /** True from onStartCommand's promotion until onDestroy. */
        @Volatile
        var running = false
            private set

        // Main thread only (MethodChannel handlers and the service callbacks).
        private var startPending = false
        private var stopRequested = false

        /**
         * Tag of the chat row the service card shows now (its id is
         * [LIVE_ROW_ID]); null: the card is the service's own copy. Written
         * on the main thread; tray readers on other threads read it.
         */
        @Volatile
        var carriedTag: String? = null
            private set

        /** That row as it was last drawn: what goes back under its tag. */
        @Volatile
        private var carriedRow: Notification? = null

        /** The service's own card (no chat): shown when no row is carried. */
        @Volatile
        private var ownCard: Notification? = null
        private var appContext: Context? = null

        /** Told when the service ends by itself: "timeout", "cap", "refused". */
        @Volatile
        var onEnded: ((String) -> Unit)? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * False when Android refuses the start (background start not allowed,
         * ForegroundServiceStartNotAllowedException, SecurityException…):
         * never thrown to the caller.
         */
        fun start(context: Context, title: String?, text: String?, capMs: Long): Boolean {
            stopRequested = false
            startPending = true
            appContext = context.applicationContext
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, HermesTurnKeepAliveService::class.java)
                        .setAction(ACTION_START)
                        .putExtra(EXTRA_TITLE, title)
                        .putExtra(EXTRA_TEXT, text)
                        .putExtra(EXTRA_CAP_MS, capMs),
                )
                true
            } catch (_: Exception) {
                Log.w(TAG, "TurnKeepAlive start refused")
                startPending = false
                false
            }
        }

        fun stop(context: Context) {
            if (startPending) {
                // onStartCommand still has to call startForeground; it stops
                // right after (a stopService now would crash the app).
                stopRequested = true
                return
            }
            running = false
            // The row goes back under its tag first, then the card goes with
            // the service, at once (Dart's cancel of the row, sent right
            // after this stop on the way back to the app, then takes it down).
            putBackCarriedRow(context)
            val app = context.applicationContext
            try {
                app.stopService(Intent(app, HermesTurnKeepAliveService::class.java))
            } catch (_: Exception) {
            }
        }

        private fun endFromNative(service: Service, reason: String) {
            Log.i(TAG, "TurnKeepAlive ended: $reason")
            running = false
            // The turn is still running (cap, system timeout): its row stays,
            // under its own tag, and Dart keeps updating it there.
            putBackCarriedRow(service)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    service.stopForeground(true)
                }
            } catch (_: Exception) {
            }
            try {
                service.stopSelf()
            } catch (_: Exception) {
            }
            notifyEnded(reason)
        }

        /** Dart learns the hold is gone; a failure to tell it is not a crash. */
        private fun notifyEnded(reason: String) {
            try {
                onEnded?.invoke(reason)
            } catch (_: Exception) {
            }
        }

        /** The service's own card in the tray (tag null, its id). */
        fun isServiceCard(tag: String?, id: Int): Boolean =
            tag == null && id == NOTIFICATION_ID

        /** The row at tag + [id] is shown now as the service card. */
        fun carries(tag: String?, id: Int): Boolean =
            running && id == LIVE_ROW_ID && tag != null && tag == carriedTag

        /**
         * A post at tag + [id] (a chat's live row, or what a tap puts in its
         * place): while the service holds, the row it carries, or the first
         * chat row when it carries none, is drawn as the service card instead
         * of a card of its own. True when it was (the caller posts nothing).
         * Called where the row is posted: the MethodChannel handlers and the
         * action receiver, on the main thread.
         */
        fun carry(context: Context, tag: String?, id: Int, notification: Notification): Boolean {
            if (!running || id != LIVE_ROW_ID || tag == null) return false
            val current = carriedTag
            if (current == null) {
                if (!HermesRichNotifications.isChatLiveRow(notification)) return false
            } else if (current != tag) {
                // Another chat's row: a card of its own (one per working chat).
                return false
            }
            return try {
                val manager = NotificationManagerCompat.from(context)
                manager.notify(NOTIFICATION_ID, serviceCard(context, notification))
                carriedTag = tag
                carriedRow = notification
                // Newly carried: a copy still under its own tag leaves (not a
                // Dart cancel: nothing is noted).
                if (current == null) manager.cancel(tag, LIVE_ROW_ID)
                true
            } catch (_: Exception) {
                false
            }
        }

        /**
         * The row at tag + [id] was taken down (Dart, the background check,
         * its engine gone). If the card showed it, the card shows the
         * next chat row in the tray, or the service's own copy (a service
         * card cannot be cancelled while the service runs).
         */
        fun rowCancelled(tag: String?, id: Int) {
            if (id != LIVE_ROW_ID || tag == null || tag != carriedTag) return
            if (Looper.myLooper() != Looper.getMainLooper()) {
                // The background worker cancels off the main thread.
                mainHandler.post {
                    if (HermesRichNotifications.cancelledRecently(tag, id)) rowCancelled(tag, id)
                }
                return
            }
            carriedTag = null
            carriedRow = null
            if (!running) return
            val context = appContext ?: return
            try {
                val next = adoptableRow(context)
                val card = next?.notification ?: ownCard ?: return
                NotificationManagerCompat.from(context)
                    .notify(NOTIFICATION_ID, serviceCard(context, card))
                if (next != null) takeIntoCard(context, next)
            } catch (_: Exception) {
            }
        }

        /** The newest chat live row in the tray under its own tag. */
        private fun adoptableRow(context: Context): StatusBarNotification? =
            try {
                context.getSystemService(NotificationManager::class.java)
                    ?.activeNotifications
                    ?.filter {
                        it.id == LIVE_ROW_ID && it.tag != null &&
                            HermesRichNotifications.isChatLiveRow(it.notification) &&
                            !HermesRichNotifications.cancelledRecently(it.tag, it.id)
                    }
                    ?.maxByOrNull { it.postTime }
            } catch (_: Exception) {
                null
            }

        /** [row] is the card now: it leaves its own tag (not a Dart cancel). */
        private fun takeIntoCard(context: Context, row: StatusBarNotification) {
            carriedTag = row.tag
            carriedRow = row.notification
            try {
                NotificationManagerCompat.from(context).cancel(row.tag, LIVE_ROW_ID)
            } catch (_: Exception) {
            }
        }

        /**
         * The carried row goes back under its own tag (the service is going
         * away), unless Dart took it down a moment ago: the system applies a
         * cancel asynchronously, and a row put back then would be a ghost.
         */
        private fun putBackCarriedRow(context: Context) {
            val tag = carriedTag
            val row = carriedRow
            carriedTag = null
            carriedRow = null
            if (tag == null || row == null) return
            if (HermesRichNotifications.cancelledRecently(tag, LIVE_ROW_ID)) return
            try {
                NotificationManagerCompat.from(context).notify(tag, LIVE_ROW_ID, row)
            } catch (_: Exception) {
            }
        }

        /**
         * [notification] as the service card: shown at once. Since Android 12
         * a foreground service's notification may be held back about 10 s;
         * the row has already left its tag, so a held card would leave the
         * turn with no card at all (and a read-only row has no button that
         * would lift the delay).
         */
        private fun serviceCard(context: Context, notification: Notification): Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    Notification.Builder.recoverBuilder(context, notification)
                        .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                        .build()
                } catch (_: Exception) {
                    notification
                }
            } else {
                notification
            }
    }
}

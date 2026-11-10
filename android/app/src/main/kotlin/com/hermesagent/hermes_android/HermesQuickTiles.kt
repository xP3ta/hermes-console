package com.hermesagent.hermes_android

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/*
 * Quick Settings tiles. Each one does what the matching button of the Chat
 * rapido widget does: it opens Console on a new chat through the same
 * allowlisted launch contract, so Flutter (not the tile) resolves the
 * instance, shows onboarding when nothing is set up and honours App Lock.
 * A tile carries no data, no secret and no network: it only starts the
 * activity, after the device is unlocked.
 */
abstract class HermesQuickTileService(
    private val target: NewSessionLaunchTarget,
) : TileService() {
    override fun onStartListening() {
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        unlockAndRun { launch() }
    }

    private fun launch() {
        val intent =
            NewSessionLaunchContract.newIntent(
                this,
                NewSessionLaunchContract.SOURCE_WIDGET,
                target,
            )
        if (Build.VERSION.SDK_INT >= 34) {
            val pending =
                PendingIntent.getActivity(
                    this,
                    target.ordinal,
                    intent,
                    PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
                )
            startActivityAndCollapse(pending)
        } else {
            collapseAndStart(intent)
        }
    }

    // Before Android 14 only the Intent form exists; it is deprecated from 14.
    @Suppress("DEPRECATION")
    private fun collapseAndStart(intent: android.content.Intent) {
        startActivityAndCollapse(intent)
    }
}

/** New chat: the composer, ready to write. */
class HermesNewChatTileService : HermesQuickTileService(NewSessionLaunchTarget.COMPOSER)

/** Voice chat: a new chat that starts in voice mode. */
class HermesVoiceChatTileService : HermesQuickTileService(NewSessionLaunchTarget.VOICE)

/** Camera chat: a new chat that opens the camera first. */
class HermesCameraChatTileService : HermesQuickTileService(NewSessionLaunchTarget.CAMERA)

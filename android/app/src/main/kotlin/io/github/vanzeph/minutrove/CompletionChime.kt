package io.github.vanzeph.minutrove

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/** A normal notification, never an alarm, media player, or DND bypass. */
class CompletionChime(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "minutrove_completion_v1"
        const val SOUND_RESOURCE = "completion_chime"
    }

    private val manager = context.getSystemService(NotificationManager::class.java)
    // Use a resource NAME, not an integer ID which can change on app upgrade.
    val soundUri: Uri = Uri.parse("android.resource://${context.packageName}/raw/$SOUND_RESOURCE")
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "Session completions", NotificationManager.IMPORTANCE_DEFAULT)
            channel.description = "One short sound when a session completes"
            channel.setSound(soundUri, attributes)
            channel.enableVibration(false)
            channel.setBypassDnd(false)
            // Existing user sound/importance choices are preserved by Android.
            manager.createNotificationChannel(channel)
        }
    }

    @Suppress("DEPRECATION")
    fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL_ID)
                      else Notification.Builder(context).setSound(soundUri, attributes)
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingIntent = PendingIntent.getActivity(context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return builder.setSmallIcon(R.drawable.ic_completion)
            .setContentTitle("Session complete")
            .setContentText("Your time is complete. Rest or begin again when ready.")
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    fun playOnce(completionId: String): String {
        createChannel()
        if (!manager.areNotificationsEnabled()) return "suppressed"
        if (Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(CHANNEL_ID).importance == NotificationManager.IMPORTANCE_NONE) {
            return "suppressed"
        }
        // No FLAG_INSISTENT, full-screen intent, repeated scheduling, volume
        // change, or request for notification-policy access.
        manager.notify("minutrove.completion.$completionId", 0, notification())
        return "submitted"
    }
}

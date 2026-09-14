package io.github.vanzeph.minutrove

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

/**
 * Schedules exactly one OS local notification for the active session run deadline.
 *
 * The persisted [NotificationIntent] rows from the Flutter store are the single
 * source of truth; every [reconcile] replaces the alarm/notification state to
 * match them, so pause (deadline null), resume (new deadline), end and crash
 * recovery all converge without extra bookkeeping. Stable identifiers are the
 * session ID (alarm identity and mirror key) and the completion ID
 * (notification tag shared with the foreground chime, so one completion can
 * alert at most once regardless of which path posted first).
 *
 * Exactness is opportunistic: [AlarmManager.setExactAndAllowWhileIdle] is used
 * only while the OS grants exact alarm access; otherwise delivery degrades to
 * an inexact allow-while-idle alarm that Doze may batch into a maintenance
 * window. Economic completion never depends on this notification being
 * delivered on time, or at all.
 */
class CompletionNotifications(private val context: Context) {
    /** One scheduled completion cue. Deadline is null when nothing is armed. */
    data class Pending(
        val sessionId: String,
        val sessionRevision: Long,
        val completionId: String,
        val deadlineUtc: Long?,
    )

    /** A settled (paused/ended/completed) intent from the Flutter store. */
    data class SettledIntent(val sessionId: String, val completionId: String, val handled: Boolean)

    data class ReconcileResult(val permission: String, val delivered: Set<String>)

    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Permission ------------------------------------------------------

    /** True when the OS would currently show one of our notifications. */
    fun canNotify(): Boolean {
        if (!notifications.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = notifications.getNotificationChannel(CompletionChime.CHANNEL_ID)
                ?: return true
            if (channel.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun hasRuntimePermission(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    /** Port values: granted, denied, notDetermined, restricted. */
    fun permissionState(): String = when {
        Build.VERSION.SDK_INT >= 33 && !hasRuntimePermission() && !permissionRequested() ->
            "notDetermined"
        canNotify() -> "granted"
        else -> "denied"
    }

    fun markPermissionRequested() {
        prefs.edit().putBoolean(KEY_PERMISSION_REQUESTED, true).commit()
    }

    /** Repeated requests with one operation ID return the recorded answer. */
    fun cachedPermissionRequest(operationId: String): String? =
        if (prefs.getString(KEY_LAST_REQUEST, null) == operationId) {
            prefs.getString(KEY_LAST_REQUEST_RESULT, null)
        } else {
            null
        }

    fun recordPermissionRequest(operationId: String, result: String) {
        prefs.edit()
            .putBoolean(KEY_PERMISSION_REQUESTED, true)
            .putString(KEY_LAST_REQUEST, operationId)
            .putString(KEY_LAST_REQUEST_RESULT, result)
            .commit()
    }

    fun openSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= 26) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            )
        }
        return try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ---- Reconcile -------------------------------------------------------

    /**
     * Replace alarm, mirror and delivered state to match [pending] (intents
     * with a deadline, normally exactly one active run) plus [settled]
     * (intents whose deadline is null: paused, ended or completed sessions).
     * Returns completion IDs whose OS notification was already delivered and
     * is still unacknowledged, so the Flutter layer can suppress a duplicate
     * foreground chime and later clear the cue by reporting handled=true.
     */
    fun reconcile(pending: List<Pending>, settled: List<SettledIntent>): ReconcileResult {
        val active = pending.associateBy { it.sessionId }
        val granted = canNotify()
        // Cancel mirror entries that no longer match the authoritative list:
        // removed, paused/ended (deadline null), replaced, or no longer
        // notifiable. Always re-arming survivors is idempotent and self-heals
        // state left behind by a killed process.
        for (stored in storedPending()) {
            if (!granted || active[stored.sessionId] != stored) cancelAlarm(stored)
        }
        if (granted) {
            for (entry in pending) schedule(entry)
        }
        prefs.edit().putString(KEY_PENDING, encodePending(if (granted) pending else emptyList()))
            .commit()

        // Keep a delivered cue only while its completion has settled, is not
        // acknowledged, and has not become active again. Acknowledged cues
        // also drop their shade notification: the app itself showed the
        // settled result.
        val settledByCompletion = settled.associateBy { it.completionId }
        val activeCompletions = pending.mapTo(mutableSetOf()) { it.completionId }
        val delivered = storedDelivered().filterTo(mutableSetOf()) { completionId ->
            completionId !in activeCompletions &&
                settledByCompletion[completionId]?.handled == false
        }
        prefs.edit().putString(KEY_DELIVERED, JSONArray(delivered).toString()).commit()
        for (entry in settled) {
            if (entry.handled) cancelNotification(entry.completionId)
        }

        // A deadline already in the past (app restored after the run finished,
        // or notifications re-enabled late) posts through the same receiver
        // path so delivery happens at most once.
        val now = System.currentTimeMillis()
        for (entry in pending) {
            val deadline = entry.deadlineUtc ?: continue
            if (granted && deadline <= now && entry.completionId !in delivered) {
                deliver(entry)
            }
        }
        return ReconcileResult(permissionState(), delivered)
    }

    // ---- Scheduling ------------------------------------------------------

    private fun schedule(entry: Pending) {
        val deadline = entry.deadlineUtc ?: return
        val pendingIntent = alarmIntent(entry)
        if (Build.VERSION.SDK_INT >= 31 && !alarms.canScheduleExactAlarms()) {
            // Doze may batch this into a maintenance window. Economic
            // completion still uses the persisted deadline, never this alarm.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, pendingIntent)
        } else {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, pendingIntent)
        }
    }

    private fun cancelAlarm(entry: Pending) {
        alarms.cancel(alarmIntent(entry))
    }

    /**
     * Distinct per session through both the request code and the intent data
     * URI, so two sessions can never collide and cancels always match.
     */
    private fun alarmIntent(entry: Pending): PendingIntent {
        val intent = Intent(context, CompletionAlarmReceiver::class.java)
            .setAction(ALARM_ACTION)
            .setData(Uri.parse("minutrove-session:${entry.sessionId}"))
            .putExtra(EXTRA_SESSION_ID, entry.sessionId)
            .putExtra(EXTRA_COMPLETION_ID, entry.completionId)
            .putExtra(EXTRA_SESSION_REVISION, entry.sessionRevision)
            .putExtra(EXTRA_DEADLINE_UTC, entry.deadlineUtc ?: -1L)
        return PendingIntent.getBroadcast(
            context,
            entry.sessionId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Alarm delivery path. Rechecks the mirror so a cue armed before a pause
     * or end whose cancel never ran (process killed between the committed
     * pause and the next reconcile) cannot post a stale completion.
     */
    fun onAlarm(sessionId: String, completionId: String, revision: Long, deadlineUtc: Long) {
        val stored = storedPending().firstOrNull { it.sessionId == sessionId } ?: return
        if (stored.completionId != completionId ||
            stored.sessionRevision != revision ||
            stored.deadlineUtc != deadlineUtc
        ) {
            return
        }
        deliver(stored)
    }

    fun deliver(entry: Pending) {
        if (!canNotify()) return
        CompletionChime(context).createChannel()
        val delivered = storedDelivered()
        if (delivered.add(entry.completionId)) {
            prefs.edit().putString(KEY_DELIVERED, JSONArray(delivered).toString()).commit()
        }
        // Same stable tag as the foreground chime path plus only-alert-once:
        // whichever path posts first owns the single audible alert.
        notifications.notify(notificationTag(entry.completionId), 0, notification(entry))
    }

    fun cancelNotification(completionId: String) {
        notifications.cancel(notificationTag(completionId), 0)
    }

    fun hasNotification(completionId: String): Boolean =
        notifications.activeNotifications.any {
            it.tag == notificationTag(completionId) && it.id == 0
        }

    fun notificationTag(completionId: String): String =
        CompletionChime.completionTag(completionId)

    private fun notification(entry: Pending): android.app.Notification =
        CompletionChime(context).notification(entry.completionId)

    // ---- Reboot / clock changes / app update ------------------------------

    /**
     * Alarms do not survive reboot or app update, and RTC alarms drift when
     * the user edits the clock or timezone. Re-arm everything still in the
     * mirror; a run whose deadline already passed posts immediately (at most
     * once, guarded by the delivered set).
     */
    fun rescheduleAfterSystemChange() {
        val now = System.currentTimeMillis()
        for (entry in storedPending()) {
            val deadline = entry.deadlineUtc ?: continue
            if (canNotify() && deadline > now) {
                schedule(entry)
            } else if (canNotify()) {
                deliver(entry)
            }
        }
    }

    fun storedPending(): List<Pending> {
        val raw = prefs.getString(KEY_PENDING, null) ?: return emptyList()
        val array = JSONArray(raw)
        val result = ArrayList<Pending>(array.length())
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            result.add(
                Pending(
                    sessionId = item.getString("sessionId"),
                    sessionRevision = item.getLong("sessionRevision"),
                    completionId = item.getString("completionId"),
                    deadlineUtc = if (item.isNull("deadlineUtc")) {
                        null
                    } else {
                        item.getLong("deadlineUtc")
                    },
                ),
            )
        }
        return result
    }

    fun storedDelivered(): MutableSet<String> {
        val raw = prefs.getString(KEY_DELIVERED, null) ?: return mutableSetOf()
        val array = JSONArray(raw)
        val result = mutableSetOf<String>()
        for (index in 0 until array.length()) result.add(array.getString(index))
        return result
    }

    fun clearForTest() {
        for (entry in storedPending()) cancelAlarm(entry)
        prefs.edit().clear().commit()
    }

    /** Test hook: cancels armed alarms the way the OS does across a reboot,
     *  while keeping the persisted mirror the boot receiver recovers from. */
    fun simulateRebootForTest() {
        for (entry in storedPending()) cancelAlarm(entry)
    }

    private fun encodePending(entries: List<Pending>): String {
        val array = JSONArray()
        for (entry in entries) {
            array.put(
                JSONObject()
                    .put("sessionId", entry.sessionId)
                    .put("sessionRevision", entry.sessionRevision)
                    .put("completionId", entry.completionId)
                    .put("deadlineUtc", entry.deadlineUtc ?: JSONObject.NULL),
            )
        }
        return array.toString()
    }

    private fun permissionRequested(): Boolean =
        prefs.getBoolean(KEY_PERMISSION_REQUESTED, false)

    companion object {
        const val METHOD_CHANNEL = "io.github.vanzeph.minutrove/notifications"
        const val ALARM_ACTION = "io.github.vanzeph.minutrove.action.COMPLETION_DEADLINE"
        const val EXTRA_SESSION_ID = "minutrove.extra.SESSION_ID"
        const val EXTRA_COMPLETION_ID = "minutrove.extra.COMPLETION_ID"
        const val EXTRA_SESSION_REVISION = "minutrove.extra.SESSION_REVISION"
        const val EXTRA_DEADLINE_UTC = "minutrove.extra.DEADLINE_UTC"
        const val EXTRA_FROM_NOTIFICATION = "minutrove.extra.FROM_NOTIFICATION"
        const val MAX_ID_LENGTH = 128
        private const val PREFS = "minutrove_completion_notifications"
        private const val KEY_PENDING = "pending"
        private const val KEY_DELIVERED = "delivered"
        private const val KEY_PERMISSION_REQUESTED = "permission_requested"
        private const val KEY_LAST_REQUEST = "last_permission_request"
        private const val KEY_LAST_REQUEST_RESULT = "last_permission_request_result"

        fun validId(value: String): Boolean =
            value.isNotEmpty() && value.length <= MAX_ID_LENGTH

        /** Parses the completion cue carried by a notification tap, if any. */
        fun launchCompletionFrom(intent: Intent): String? {
            if (!intent.getBooleanExtra(EXTRA_FROM_NOTIFICATION, false)) return null
            val completionId = intent.getStringExtra(EXTRA_COMPLETION_ID) ?: return null
            return if (validId(completionId)) completionId else null
        }
    }
}

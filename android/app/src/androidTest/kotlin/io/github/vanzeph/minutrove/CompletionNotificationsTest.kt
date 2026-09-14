package io.github.vanzeph.minutrove

import android.app.Instrumentation
import android.app.Notification
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import java.io.FileInputStream
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Behavioral scheduling tests on a real Android framework (CI emulator).
 * Every assertion observes an actual notification or its absence, so pause,
 * resume, end, denial, lock, termination-gap and reboot recovery are covered
 * through the same AlarmManager and NotificationManager paths production
 * uses. Settlement itself is owned by the Flutter session ledger and is not
 * asserted here; these tests prove the OS cue fires or is suppressed exactly
 * once. Scheduling policy notes: delivery is best effort under Doze and
 * exact-alarm access; on-time delivery is not guaranteed and never required
 * for correct settlement.
 */
class CompletionNotificationsTest {
    private val instrumentation: Instrumentation =
        InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private lateinit var notifications: CompletionNotifications

    private val sessionA = "00000000-0000-4000-8000-00000000000a"
    private val completionA = "00000000-0000-4000-8000-00000000000b"
    private val sessionB = "00000000-0000-4000-8000-00000000000c"
    private val completionB = "00000000-0000-4000-8000-00000000000d"

    @Before
    fun setUp() {
        notifications = CompletionNotifications(context)
        grantPostNotifications()
        CompletionChime(context).createChannel()
        clearState()
    }

    @After
    fun tearDown() {
        grantPostNotifications()
        wakeScreen()
        clearState()
    }

    private fun clearState() {
        notifications.clearForTest()
        context.getSystemService(android.app.NotificationManager::class.java).cancelAll()
    }

    private fun grantPostNotifications() {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            runShell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
        }
    }

    private fun revokePostNotifications() {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            runShell("pm revoke ${context.packageName} android.permission.POST_NOTIFICATIONS")
        }
    }

    private fun runShell(command: String) {
        instrumentation.uiAutomation.executeShellCommand(command).use { fd ->
            FileInputStream(fd.fileDescriptor).use { it.readBytes() }
        }
    }

    private fun pending(
        sessionId: String,
        completionId: String,
        deadlineUtc: Long,
        revision: Long = 1,
    ) = CompletionNotifications.Pending(sessionId, revision, completionId, deadlineUtc)

    private fun settled(
        sessionId: String,
        completionId: String,
        handled: Boolean,
    ) = CompletionNotifications.SettledIntent(sessionId, completionId, handled)

    private fun deadlineIn(milliseconds: Long): Long =
        System.currentTimeMillis() + milliseconds

    /** Polls until [condition] holds, or fails with [label]. */
    private fun await(label: String, timeoutMs: Long, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(100)
        }
        assertFalse("Timed out waiting for: $label", true)
    }

    private fun assertNeverHappens(label: String, waitMs: Long, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + waitMs
        while (System.currentTimeMillis() < deadline) {
            assertFalse("Unexpectedly observed: $label", condition())
            Thread.sleep(100)
        }
    }

    private fun wakeScreen() {
        runShell("input keyevent KEYCODE_WAKEUP")
        runShell("wm dismiss-keyguard")
    }

    private fun isInteractive(): Boolean =
        context.getSystemService(android.os.PowerManager::class.java).isInteractive

    // ---- Permission -------------------------------------------------------

    @Test fun permissionMapsUndeterminedDeniedAndGrantedStates() {
        assertTrue(notifications.canNotify())
        assertEquals("granted", notifications.permissionState())

        if (android.os.Build.VERSION.SDK_INT >= 33) {
            notifications.clearForTest()
            revokePostNotifications()
            // Fresh-install state: the runtime permission is ungranted and no
            // contextual request has been made yet.
            assertEquals("notDetermined", notifications.permissionState())

            // After a first contextual request that the user denied, the same
            // OS state reads as denied: re-prompting is not promised.
            notifications.markPermissionRequested()
            assertEquals("denied", notifications.permissionState())

            grantPostNotifications()
            assertEquals("granted", notifications.permissionState())
        }
    }

    @Test fun requestIsIdempotentPerOperationId() {
        val state = notifications.cachedPermissionRequest("op-1")
            ?: notifications.permissionState().also {
                notifications.recordPermissionRequest("op-1", it)
            }
        assertEquals("granted", state)
        // A repeated identical request replays the recorded answer instead of
        // prompting again; a different operation id consults current state.
        assertEquals("granted", notifications.cachedPermissionRequest("op-1"))
        assertNull(notifications.cachedPermissionRequest("op-2"))
    }

    // ---- Scheduling and pause/resume/end cancellation -----------------------

    @Test fun runningDeadlineFiresExactlyOneCompletionCue() {
        val deadline = deadlineIn(2500)
        val outcome = notifications.reconcile(
            listOf(pending(sessionA, completionA, deadline)),
            listOf(),
        )
        assertEquals("granted", outcome.permission)
        assertTrue(outcome.delivered.isEmpty())
        await("deadline notification", 10000) { notifications.hasNotification(completionA) }
        assertEquals(setOf(completionA), notifications.storedDelivered())
        // The posted cue uses the shared stable tag and only-alert-once, so a
        // duplicate post of the same completion can never alert twice.
        val posted = context.getSystemService(android.app.NotificationManager::class.java)
            .activeNotifications
            .single { it.tag == notifications.notificationTag(completionA) }
        assertTrue(posted.notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        assertEquals(0, posted.notification.flags and Notification.FLAG_INSISTENT)
        assertNull(posted.notification.fullScreenIntent)
    }

    @Test fun pauseCancelsTheArmedCueCompletely() {
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2500))),
            listOf(),
        )
        // Pause persists a null deadline; reconcile must cancel the alarm so
        // the paused session never completes or alerts on its own.
        notifications.reconcile(listOf(), listOf(settled(sessionA, completionA, handled = false)))
        assertNeverHappens("paused-session notification", 6000) {
            notifications.hasNotification(completionA)
        }
        assertTrue(notifications.storedPending().isEmpty())
        assertTrue(notifications.storedDelivered().isEmpty())
    }

    @Test fun resumeRearmsAtTheNewDeadlineOnly() {
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2000))),
            listOf(),
        )
        notifications.reconcile(
            listOf(),
            listOf(settled(sessionA, completionA, handled = false)), // pause
        )
        assertNeverHappens("pre-resume notification", 3500) {
            notifications.hasNotification(completionA)
        }
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2000), revision = 2)),
            listOf(),
        )
        await("resumed notification", 10000) { notifications.hasNotification(completionA) }
        assertEquals(setOf(completionA), notifications.storedDelivered())
    }

    @Test fun endCancelsTheCueAndAcknowledgedCompletionsClearTheShade() {
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2500))),
            listOf(),
        )
        await("completion cue", 10000) { notifications.hasNotification(completionA) }
        // End: deadline null. The completion already alerted, the app shows
        // the settled result, and acknowledgement (handled=true) clears the
        // delivered cue and its shade notification.
        val afterEnd = notifications.reconcile(
            listOf(),
            listOf(settled(sessionA, completionA, handled = false)),
        )
        assertEquals(setOf(completionA), afterEnd.delivered)
        assertTrue(notifications.hasNotification(completionA))
        val acknowledged = notifications.reconcile(
            listOf(),
            listOf(settled(sessionA, completionA, handled = true)),
        )
        assertTrue(acknowledged.delivered.isEmpty())
        assertFalse(notifications.hasNotification(completionA))
        assertTrue(notifications.storedDelivered().isEmpty())
    }

    @Test fun deniedPermissionSuppressesSchedulingAndDelivery() {
        if (android.os.Build.VERSION.SDK_INT < 33) {
            // Pre-13 images cannot revoke per-app notification delivery from
            // the shell; denial is covered by the API 33+ branch in CI.
            return
        }
        revokePostNotifications()
        notifications.markPermissionRequested()
        assertEquals("denied", notifications.permissionState())
        val outcome = notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2500))),
            listOf(),
        )
        assertEquals("denied", outcome.permission)
        assertTrue(outcome.delivered.isEmpty())
        // Nothing is armed while delivery is impossible: re-enabling in system
        // settings followed by the next reconcile re-arms from the intent.
        assertTrue(notifications.storedPending().isEmpty())
        assertNeverHappens("denied notification", 6000) {
            notifications.hasNotification(completionA)
        }
        grantPostNotifications()
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2500))),
            listOf(),
        )
        await("re-enabled notification", 10000) { notifications.hasNotification(completionA) }
    }

    // ---- Lock, termination gap, reboot --------------------------------------

    @Test fun cueStillFiresWhileTheScreenIsOff() {
        runShell("input keyevent KEYCODE_SLEEP")
        await("display asleep", 5000) { !isInteractive() }
        try {
            notifications.reconcile(
                listOf(pending(sessionA, completionA, deadlineIn(2500))),
                listOf(),
            )
            await("screen-off notification", 12000) {
                notifications.hasNotification(completionA)
            }
            assertEquals(setOf(completionA), notifications.storedDelivered())
        } finally {
            wakeScreen()
        }
        assertTrue(isInteractive())
    }

    @Test fun alarmLeftBehindByATerminatedProcessCannotPostAStaleCue() {
        // The pause/end commit and the next reconcile are separate steps. If
        // the process dies in between, an armed alarm survives while the
        // persisted intent has moved on; the receiver must drop the stale cue.
        notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(2500))),
            listOf(),
        )
        // Simulate the crash gap: the durable intent row is settled, but the
        // alarm cancel never ran. The mirror is rewritten exactly as the next
        // successful reconcile would have written it.
        context.getSharedPreferences("minutrove_completion_notifications", Context.MODE_PRIVATE)
            .edit().putString("pending", "[]").commit()
        assertNeverHappens("stale termination-gap notification", 6000) {
            notifications.hasNotification(completionA)
        }
        assertTrue(notifications.storedDelivered().isEmpty())
    }

    @Test fun rebootReceiverRearmsASurvivingFutureDeadline() {
        val deadline = deadlineIn(2500)
        notifications.reconcile(listOf(pending(sessionA, completionA, deadline)), listOf())
        notifications.simulateRebootForTest() // The OS clears alarms on reboot.
        CompletionRescheduleReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED),
        )
        await("post-reboot notification", 10000) { notifications.hasNotification(completionA) }
        assertEquals(setOf(completionA), notifications.storedDelivered())
    }

    @Test fun rebootReceiverDeliversARunThatCompletedWhilePoweredOff() {
        val deadline = deadlineIn(2500)
        notifications.reconcile(listOf(pending(sessionA, completionA, deadline)), listOf())
        notifications.simulateRebootForTest()
        // The device comes back after the deadline passed while powered off.
        context.getSharedPreferences("minutrove_completion_notifications", Context.MODE_PRIVATE)
            .edit()
            .putString(
                "pending",
                JSONArray()
                    .put(
                        JSONObject()
                            .put("sessionId", sessionA)
                            .put("sessionRevision", 1L)
                            .put("completionId", completionA)
                            .put("deadlineUtc", System.currentTimeMillis() - 60000),
                    )
                    .toString(),
            )
            .commit()
        CompletionRescheduleReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED),
        )
        await("powered-off completion notification", 5000) {
            notifications.hasNotification(completionA)
        }
        // Recovery delivers at most once even if the receiver runs again.
        CompletionRescheduleReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED),
        )
        val count = context.getSystemService(android.app.NotificationManager::class.java)
            .activeNotifications.count { it.tag == notifications.notificationTag(completionA) }
        assertEquals(1, count)
    }

    // ---- Re-entry and tap routing -------------------------------------------

    @Test fun completionCueTapOpensTheAppAndCarriesTheCompletionIdentity() {
        val notification = CompletionChime(context).notification(completionA)
        val routed = CompletionNotifications.launchCompletionFrom(
            Intent(context, MainActivity::class.java)
                .putExtra(CompletionNotifications.EXTRA_FROM_NOTIFICATION, true)
                .putExtra(CompletionNotifications.EXTRA_COMPLETION_ID, completionA),
        )
        assertEquals(completionA, routed)
        // Not a cue launch: a regular launcher entry routes nowhere, and a
        // malformed completion identity is dropped rather than trusted.
        assertNull(
            CompletionNotifications.launchCompletionFrom(
                Intent(context, MainActivity::class.java),
            ),
        )
        assertNull(
            CompletionNotifications.launchCompletionFrom(
                Intent(context, MainActivity::class.java)
                    .putExtra(CompletionNotifications.EXTRA_FROM_NOTIFICATION, true)
                    .putExtra(CompletionNotifications.EXTRA_COMPLETION_ID, "x".repeat(129)),
            ),
        )
        // The tap intent really resolves to the single-top main activity.
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        try {
            notification.contentIntent!!.send()
            assertNotNull(
                "Tap did not launch the app",
                monitor.waitForActivityWithTimeout(20000),
            )
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    @Test fun reconciliationConvergesFromArbitraryStaleOsState() {
        // A previous install/process left two armed cues; one reconcile
        // against current intents cancels every cue no longer scheduled.
        notifications.reconcile(
            listOf(
                pending(sessionA, completionA, deadlineIn(15000)),
                pending(sessionB, completionB, deadlineIn(16000)),
            ),
            listOf(),
        )
        assertEquals(2, notifications.storedPending().size)
        val outcome = notifications.reconcile(
            listOf(pending(sessionA, completionA, deadlineIn(15000))),
            listOf(settled(sessionB, completionB, handled = true)),
        )
        assertEquals(1, notifications.storedPending().size)
        assertEquals(sessionA, notifications.storedPending().single().sessionId)
        assertTrue(outcome.delivered.isEmpty())
        assertFalse(notifications.hasNotification(completionB))
    }
}

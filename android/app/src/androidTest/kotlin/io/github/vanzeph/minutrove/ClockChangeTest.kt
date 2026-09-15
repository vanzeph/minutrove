package io.github.vanzeph.minutrove

import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import java.io.FileInputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * Manual clock edits on a real Android framework (CI google_apis emulator,
 * where `su 0` is available to the shell). The deadline cue is an RTC alarm,
 * so wall-clock edits move delivery; these tests pin the observable contract:
 * a forward edit that passes the deadline delivers the cue at most once, a
 * backward edit re-arms the future deadline instead of firing it, and the
 * durable clock keeps wall time, boot identity and monotonic time coherent
 * across the edit. Economic settlement itself is anchored by the persisted
 * deadline and monotonic samples and is owned by the Flutter ledger; it is
 * asserted in the Dart recovery suites, not here.
 */
class ClockChangeTest {
    private val instrumentation: Instrumentation =
        InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private lateinit var notifications: CompletionNotifications

    private val sessionA = "00000000-0000-4000-8000-000000000010"
    private val completionA = "00000000-0000-4000-8000-000000000011"

    @Before
    fun setUp() {
        notifications = CompletionNotifications(context)
        // Toybox `date` SET parsing on the oldest supported images (API 24)
        // is unreliable and destabilizes the framework process, so the
        // automated edit runs only where the format is known-good; manual
        // clock-change verification on Android 7 stays on the device list.
        assumeTrue(
            "automated clock edits run on API 26+ emulator images",
            android.os.Build.VERSION.SDK_INT >= 26,
        )
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                android.Manifest.permission.POST_NOTIFICATIONS,
            )
        }
        assumeTrue(
            "POST_NOTIFICATIONS baseline not granted before test",
            notifications.canNotify(),
        )
        assumeTrue(
            "changing the system clock needs root (google_apis emulator image)",
            canSetWallClock(),
        )
        CompletionChime(context).createChannel()
        clearState()
    }

    @After
    fun tearDown() {
        clearState()
    }

    private fun clearState() {
        notifications.clearForTest()
        context.getSystemService(android.app.NotificationManager::class.java).cancelAll()
    }

    private fun runShell(command: String): String =
        instrumentation.uiAutomation.executeShellCommand(command).use { fd ->
            FileInputStream(fd.fileDescriptor).use { it.readBytes().decodeToString() }
        }

    /** Captures wall and monotonic time so the clock can be restored exactly. */
    private class WallSnapshot(val utcMillis: Long, val monotonicMillis: Long)

    private fun snapshot(): WallSnapshot =
        WallSnapshot(System.currentTimeMillis(), SystemClock.elapsedRealtime())

    /**
     * Moves the system clock so that wall time equals [snapshot] plus
     * [offsetMillis], accounting for real elapsed time since the snapshot.
     * Returns false when the shell could not apply the edit.
     */
    private fun setWallClock(snapshot: WallSnapshot, offsetMillis: Long): Boolean {
        val targetUtc =
            snapshot.utcMillis + offsetMillis +
                (SystemClock.elapsedRealtime() - snapshot.monotonicMillis)
        // toybox date SET form MMDDhhmmCCYY.ss in UTC.
        val format = java.text.SimpleDateFormat("MMddHHmmyyyy.ss", java.util.Locale.ROOT)
        format.timeZone = java.util.TimeZone.getTimeZone("UTC")
        val rendered = format.format(java.util.Date(targetUtc))
        runShell("su 0 date -u $rendered")
        return kotlin.math.abs(System.currentTimeMillis() - targetUtc) < 15_000
    }

    private fun canSetWallClock(): Boolean = setWallClock(snapshot(), 0)

    private fun pending(deadlineUtc: Long) =
        CompletionNotifications.Pending(sessionA, 1, completionA, deadlineUtc)

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

    @Test fun forwardClockEditDeliversThePassedDeadlineExactlyOnce() {
        val clock = DurableClock(context)
        val before = clock.now()
        val cue = snapshot()
        val deadline = System.currentTimeMillis() + 45_000
        notifications.reconcile(listOf(pending(deadline)), listOf())
        assertTrue(notifications.storedPending().isNotEmpty())
        try {
            // The user moves the wall clock two minutes past the deadline.
            assertTrue("forward clock edit did not apply", setWallClock(cue, 120_000))
            // The system TIME_SET broadcast re-arms through the receiver; a
            // deadline now in the past posts through the same receiver path.
            await("clock-jump delivery", 30_000) {
                notifications.hasNotification(completionA) &&
                    notifications.storedDelivered() == setOf(completionA)
            }
            // The durable clock stays coherent: same boot, wall time jumped
            // with the edit, monotonic time never moved backwards.
            val after = clock.now()
            assertEquals(before["bootId"], after["bootId"])
            assertTrue(
                "wall time should follow the manual edit",
                (after["utcMilliseconds"] as Long) - (before["utcMilliseconds"] as Long) >
                    100_000,
            )
            assertTrue(
                "monotonic time must stay continuous across clock edits",
                (after["monotonicMilliseconds"] as Long) >=
                    (before["monotonicMilliseconds"] as Long),
            )
            assertTrue(
                "monotonic time must not jump with the wall clock",
                (after["monotonicMilliseconds"] as Long) -
                    (before["monotonicMilliseconds"] as Long) < 30_000,
            )
            // A repeated system change cannot deliver a second cue.
            CompletionRescheduleReceiver().onReceive(
                context,
                Intent(Intent.ACTION_TIME_CHANGED),
            )
            Thread.sleep(1_000)
            val count = context.getSystemService(android.app.NotificationManager::class.java)
                .activeNotifications.count {
                    it.tag == notifications.notificationTag(completionA)
                }
            assertEquals(1, count)
            assertEquals(setOf(completionA), notifications.storedDelivered())
        } finally {
            setWallClock(cue, 0)
        }
    }

    @Test fun backwardClockEditRearmsTheFutureDeadlineInsteadOfFiringIt() {
        val cue = snapshot()
        val deadline = System.currentTimeMillis() + 8_000
        notifications.reconcile(listOf(pending(deadline)), listOf())
        try {
            // The user moves the wall clock one minute behind the deadline.
            assertTrue("backward clock edit did not apply", setWallClock(cue, -60_000))
            CompletionRescheduleReceiver().onReceive(
                context,
                Intent(Intent.ACTION_TIME_CHANGED),
            )
            // Nothing may fire while the deadline is in the future again...
            assertNeverHappens("premature cue after backward edit", 6_000) {
                notifications.hasNotification(completionA)
            }
            assertTrue(notifications.storedDelivered().isEmpty())
            // ...and the cue stays armed at its original wall deadline.
            val armed = notifications.storedPending().single()
            assertEquals(sessionA, armed.sessionId)
            assertEquals(deadline, armed.deadlineUtc)
        } finally {
            setWallClock(cue, 0)
        }
        // After the edit is undone the deadline is still only seconds away;
        // the re-armed cue may now fire normally, exactly once.
        await("post-restore delivery", 20_000) {
            notifications.hasNotification(completionA)
        }
        assertEquals(setOf(completionA), notifications.storedDelivered())
    }
}

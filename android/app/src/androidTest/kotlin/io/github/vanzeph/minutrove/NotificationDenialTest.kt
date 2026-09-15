package io.github.vanzeph.minutrove

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Runs with POST_NOTIFICATIONS already revoked by the harness (see
 * tool/test_android_chime.sh): a live runtime-permission revoke would kill
 * this process, so the script flips the permission while the app is not
 * running and launches this class separately. On API 33+ a fresh install
 * with no request reads as notDetermined; after a first declined request
 * the same OS state reads as denied, scheduling is suppressed, and the
 * system-settings action is offered so delivery can be re-enabled.
 */
class NotificationDenialTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private lateinit var notifications: CompletionNotifications

    private val sessionA = "00000000-0000-4000-8000-00000000000e"
    private val completionA = "00000000-0000-4000-8000-00000000000f"

    @Before
    fun setUp() {
        notifications = CompletionNotifications(context)
        notifications.clearForTest()
        context.getSystemService(android.app.NotificationManager::class.java).cancelAll()
    }

    @After
    fun tearDown() {
        notifications.clearForTest()
        context.getSystemService(android.app.NotificationManager::class.java).cancelAll()
    }

    private fun deniedByOs(): Boolean =
        android.os.Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED

    /** A plain gradle connected run keeps the permission granted: skip. */
    private fun denialStateMissing(): Boolean = !deniedByOs()

    @Test fun undeterminedAndDeniedReadDistinctlyAfterARequest() {
        if (denialStateMissing()) return
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            // Fresh install: ungranted and never asked reads as notDetermined.
            assertEquals("notDetermined", notifications.permissionState())
            // The user declined the one contextual prompt: same OS state now
            // reads as denied; re-prompting is not promised.
            notifications.markPermissionRequested()
            assertEquals("denied", notifications.permissionState())
        } else {
            // Pre-13 has no runtime prompt; delivery is disabled in Settings.
            assertEquals("denied", notifications.permissionState())
        }
    }

    @Test fun deniedPermissionSuppressesSchedulingAndDelivery() {
        if (denialStateMissing()) return
        val deadline = System.currentTimeMillis() + 2500
        val outcome = notifications.reconcile(
            listOf(
                CompletionNotifications.Pending(
                    sessionA,
                    1,
                    completionA,
                    deadline,
                ),
            ),
            listOf(),
        )
        // Nothing is armed while delivery is impossible: re-enabling in system
        // settings followed by the next reconcile re-arms from the intent.
        assertTrue(outcome.delivered.isEmpty())
        assertTrue(notifications.storedPending().isEmpty())
        val end = System.currentTimeMillis() + 6000
        while (System.currentTimeMillis() < end) {
            assertFalse(
                "Unexpected notification while denied",
                notifications.hasNotification(completionA),
            )
            Thread.sleep(100)
        }
        assertTrue(notifications.storedDelivered().isEmpty())
    }

    @Test fun pastDeadlineUnderDenialNeverDeliversOrAlerts() {
        if (denialStateMissing()) return
        val outcome = notifications.reconcile(
            listOf(
                CompletionNotifications.Pending(
                    sessionA,
                    1,
                    completionA,
                    System.currentTimeMillis() - 60000,
                ),
            ),
            listOf(),
        )
        assertTrue(outcome.delivered.isEmpty())
        assertFalse(notifications.hasNotification(completionA))
        assertTrue(notifications.storedDelivered().isEmpty())
        // The settings action remains available so the user can re-enable.
        assertTrue(notifications.openSettings())
    }
}

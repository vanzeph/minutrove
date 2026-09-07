package io.github.vanzeph.minutrove

import android.app.Notification
import android.app.NotificationManager
import android.media.MediaPlayer
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class CompletionChimeTest {
    @Test fun durableClockHasStableBootAndFreshMonotonicSamples() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val first = DurableClock(context).now()
        Thread.sleep(50)
        val second = DurableClock(context).now()
        assertEquals(first["bootId"], second["bootId"])
        assertTrue((first["bootId"] as String).startsWith("android-boot-"))
        assertTrue((second["monotonicMilliseconds"] as Long) -
            (first["monotonicMilliseconds"] as Long) >= 40)
        assertTrue(kotlin.math.abs((second["utcMilliseconds"] as Long) -
            System.currentTimeMillis()) < 1000)
    }

    @Test fun bundledAssetDecodesAndPlaysExactlyOnce() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val completed = CountDownLatch(1)
        val count = AtomicInteger()
        lateinit var player: MediaPlayer
        instrumentation.runOnMainSync {
            player = MediaPlayer.create(instrumentation.targetContext, R.raw.completion_chime)
            assertNotNull(player)
            assertTrue(player.duration in 1070..1090)
            player.isLooping = false
            player.setOnCompletionListener { count.incrementAndGet(); completed.countDown() }
            player.start()
        }
        try {
            assertTrue("No native completion callback", completed.await(5, TimeUnit.SECONDS))
            Thread.sleep(1300)
            assertEquals(1, count.get())
            assertFalse(player.isPlaying)
            assertFalse(player.isLooping)
        } finally {
            instrumentation.runOnMainSync { player.release() }
        }
    }

    @Test fun notificationUsesPackagedSoundAndNeverRepeatsOrBypassesPolicy() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val chime = CompletionChime(context)
        chime.createChannel()
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = manager.getNotificationChannel(CompletionChime.CHANNEL_ID)
        assertEquals(chime.soundUri, channel.sound)
        assertFalse(channel.canBypassDnd())
        assertFalse(channel.shouldVibrate())
        context.contentResolver.openAssetFileDescriptor(channel.sound, "r")!!.use {
            assertTrue(it.length > 0)
        }
        val notification = chime.notification()
        assertEquals(0, notification.flags and Notification.FLAG_INSISTENT)
        assertTrue(notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        assertNull(notification.fullScreenIntent)
        assertEquals(CompletionChime.CHANNEL_ID, notification.channelId)
    }
}

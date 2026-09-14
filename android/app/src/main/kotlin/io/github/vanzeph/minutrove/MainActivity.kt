package io.github.vanzeph.minutrove

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val notifications by lazy { CompletionNotifications(this) }
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionOperation: String? = null
    private var launchCompletionId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureLaunchCompletion(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureLaunchCompletion(intent)
    }

    /** Tap routing: remember which completion cue opened or re-entered the app. */
    private fun captureLaunchCompletion(intent: Intent?) {
        launchCompletionId = intent
            ?.let { CompletionNotifications.launchCompletionFrom(it) }
            ?: launchCompletionId
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val clock = DurableClock(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.vanzeph.minutrove/clock").setMethodCallHandler { call, result ->
            if (call.method != "now") {
                result.notImplemented()
            } else {
                try {
                    result.success(clock.now())
                } catch (_: Exception) {
                    result.error("clock_unavailable", "Could not sample system clock", null)
                }
            }
        }
        val chime = CompletionChime(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.vanzeph.minutrove/completion_chime").setMethodCallHandler { call, result ->
            if (call.method != "playOnce") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val id = call.argument<String>("completionId")
            if (id.isNullOrEmpty() || id.length > 128) {
                result.error("invalid_completion_id", "A completion ID is required", null)
                return@setMethodCallHandler
            }
            try {
                result.success(chime.playOnce(id))
            } catch (_: Exception) {
                result.error("chime_submission_failed", "Could not submit completion sound", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            CompletionNotifications.METHOD_CHANNEL).setMethodCallHandler { call, result ->
            handleNotificationCall(call.method, call.arguments, result)
        }
    }

    private fun handleNotificationCall(
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "permission" -> result.success(notifications.permissionState())
            "requestPermission" -> requestPermission(arguments, result)
            "reconcile" -> reconcile(arguments, result)
            "openSettings" -> result.success(notifications.openSettings())
            "consumeLaunchCompletion" -> result.success(
                launchCompletionId.also { launchCompletionId = null },
            )
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: run {
            result.error("invalid_arguments", "Expected request arguments", null)
            return
        }
        val operationId = args["operationId"] as? String
        if (operationId.isNullOrEmpty() || operationId.length > 128) {
            result.error("invalid_operation_id", "An operation ID is required", null)
            return
        }
        notifications.cachedPermissionRequest(operationId)?.let {
            result.success(it)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && !notifications.hasRuntimePermission()) {
            pendingPermissionResult = result
            pendingPermissionOperation = operationId
            notifications.markPermissionRequested()
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS,
            )
            // The dialog answer arrives in onRequestPermissionsResult.
        } else {
            val state = notifications.permissionState()
            notifications.recordPermissionRequest(operationId, state)
            result.success(state)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == REQUEST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val operationId = pendingPermissionOperation
            val state = if (granted && notifications.canNotify()) "granted" else "denied"
            if (operationId != null) {
                notifications.recordPermissionRequest(operationId, state)
            }
            pendingPermissionOperation = null
            pendingPermissionResult?.success(state)
            pendingPermissionResult = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        // Never leave a channel call unanswered if the activity dies mid-dialog.
        pendingPermissionResult?.error("permission_request_cancelled", "Activity destroyed", null)
        pendingPermissionResult = null
        pendingPermissionOperation = null
        super.onDestroy()
    }

    private fun reconcile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: run {
            result.error("invalid_arguments", "Expected reconcile arguments", null)
            return
        }
        val rawIntents = args["intents"] as? List<*> ?: run {
            result.error("invalid_intents", "Expected an intent list", null)
            return
        }
        val pending = ArrayList<CompletionNotifications.Pending>()
        val settled = ArrayList<CompletionNotifications.SettledIntent>()
        for (raw in rawIntents) {
            val item = raw as? Map<*, *> ?: run {
                result.error("invalid_intents", "Malformed notification intent", null)
                return
            }
            val sessionId = item["sessionId"] as? String
            val completionId = item["completionId"] as? String
            val revision = (item["sessionRevision"] as? Number)?.toLong()
            val handled = item["handled"] as? Boolean
            if (sessionId == null || completionId == null || revision == null ||
                handled == null || revision < 1 ||
                !CompletionNotifications.validId(sessionId) ||
                !CompletionNotifications.validId(completionId)
            ) {
                result.error("invalid_intents", "Malformed notification intent", null)
                return
            }
            val deadline = (item["deadlineUtcMilliseconds"] as? Number)?.toLong()
            if (deadline == null) {
                settled.add(
                    CompletionNotifications.SettledIntent(
                        sessionId = sessionId,
                        completionId = completionId,
                        handled = handled,
                    ),
                )
            } else {
                pending.add(
                    CompletionNotifications.Pending(
                        sessionId = sessionId,
                        sessionRevision = revision,
                        completionId = completionId,
                        deadlineUtc = deadline,
                    ),
                )
            }
        }
        try {
            val outcome = notifications.reconcile(pending, settled)
            result.success(
                mapOf(
                    "permission" to outcome.permission,
                    "delivered" to outcome.delivered.toList(),
                ),
            )
        } catch (_: Exception) {
            result.error("reconcile_failed", "Could not reconcile notifications", null)
        }
    }

    companion object {
        private const val REQUEST_NOTIFICATIONS = 4101
    }
}

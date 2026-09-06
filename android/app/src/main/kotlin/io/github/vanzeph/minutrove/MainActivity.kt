package io.github.vanzeph.minutrove

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }
}

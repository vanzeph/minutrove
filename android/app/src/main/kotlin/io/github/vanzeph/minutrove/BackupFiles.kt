package io.github.vanzeph.minutrove

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Owns the OS file interactions behind the Dart [BackupFilePicker] and
 * [BackupFileSharer] interfaces: one `.minutrove` document pick for restore
 * and one share-sheet hand-off for export.
 *
 * Both operations are user-driven UI, so an answer arrives only after the
 * user closes the presented sheet. Cancelling the picker answers null;
 * nothing is read and nothing changes. Sharing stages the immutable export
 * in the app's cache only for the hand-off and removes it afterwards.
 */
class BackupFiles(private val activity: ComponentActivity) {
    companion object {
        const val channelName = "io.github.vanzeph.minutrove/files"
        const val fileExtension = "minutrove"
        private val pickMimeTypes = arrayOf("*/*")
    }

    private var pendingResult: MethodChannel.Result? = null

    private val picker = activity.activityResultRegistry.register(
        "minutrove_backup_pick", activity,
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        val result = pendingResult
        pendingResult = null
        if (uri == null) {
            // Cancellation is an expected answer, not an error.
            result?.success(null)
            return@register
        }
        try {
            val bytes = activity.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null) {
                result?.error("pick_read_failed", "Could not read the selected file", null)
            } else {
                result?.success(bytes)
            }
        } catch (_: Exception) {
            result?.error("pick_read_failed", "Could not read the selected file", null)
        }
    }

    fun handle(call: MethodChannel.Call, result: MethodChannel.Result) {
        when (call.method) {
            "pickBackup" -> {
                if (pendingResult != null) {
                    result.error("pick_already_active", "A file picker is already open", null)
                    return
                }
                pendingResult = result
                picker.launch(pickMimeTypes)
            }
            "shareBackup" -> {
                val fileName = call.argument<String>("fileName")
                val bytes = call.argument<ByteArray>("bytes")
                if (fileName.isNullOrEmpty() || fileName.length > 128 ||
                    !fileName.endsWith(".$fileExtension") || fileName.contains("/") ||
                    bytes == null
                ) {
                    result.error("invalid_share_request", "A .minutrove file name and bytes are required", null)
                    return
                }
                share(fileName, bytes, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun share(fileName: String, bytes: ByteArray, result: MethodChannel.Result) {
        try {
            val directory = File(activity.cacheDir, "exports").apply { mkdirs() }
            // A stale staged file from an interrupted share must not be handed out.
            directory.listFiles()?.forEach { it.delete() }
            val staged = File(directory, fileName)
            staged.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(
                activity, "${activity.packageName}.fileprovider", staged)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(intent, fileName))
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.error("share_unavailable", "No app can share this file", null)
        } catch (_: Exception) {
            result.error("share_failed", "Could not stage the backup for sharing", null)
        }
    }
}

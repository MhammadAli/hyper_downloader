package com.hyperdownload.hyper_download_client

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val engineExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingSharedUrl: String? = null
    private var platformIntentChannel: MethodChannel? = null
    private var promptedAllFilesAccess = false

    @Volatile
    private var downloadSink: EventChannel.EventSink? = null

    @Volatile
    private var playlistSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureTransferPermissions()
        extractSharedUrl(intent)?.let { url ->
            pendingSharedUrl = url
        }
        maybeRunPhaseAProof(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractSharedUrl(intent)?.let { url ->
            val channel = platformIntentChannel
            if (channel != null) {
                mainHandler.post { channel.invokeMethod("onSharedUrl", url) }
            } else {
                pendingSharedUrl = url
            }
        }
        maybeRunPhaseAProof(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        platformIntentChannel = MethodChannel(messenger, PLATFORM_INTENT_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialSharedUrl" -> {
                        val url = pendingSharedUrl
                        pendingSharedUrl = null
                        result.success(url)
                    }

                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(messenger, ENGINE_CHANNEL).setMethodCallHandler { call, result ->
            handleEngineMethodCall(call, result)
        }

        registerJsonEventChannel(
            messenger = messenger,
            channelName = DOWNLOAD_PROGRESS_CHANNEL,
            attach = { sink ->
                downloadSink = sink
                AndroidDownloadEngine.setDownloadEventEmitter { json ->
                    mainHandler.post { downloadSink?.success(json) }
                }
            },
            detach = {
                downloadSink = null
                AndroidDownloadEngine.setDownloadEventEmitter(null)
            },
        )

        registerJsonEventChannel(
            messenger = messenger,
            channelName = PLAYLIST_PROGRESS_CHANNEL,
            attach = { sink ->
                playlistSink = sink
                AndroidDownloadEngine.setPlaylistEventEmitter { json ->
                    mainHandler.post { playlistSink?.success(json) }
                }
            },
            detach = {
                playlistSink = null
                AndroidDownloadEngine.setPlaylistEventEmitter(null)
            },
        )
    }

    private fun handleEngineMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ping" -> result.success("pong")
            "engineVersion" -> result.success("0.1.0-android")

            "runDiagnostics" -> dispatchAsync(result, "DIAGNOSTICS_FAILED") {
                AndroidDownloadEngine.runDiagnostics(applicationContext)
            }

            "extractRawInfo" -> {
                val url = requireArg(call, result, "url") ?: return
                val isPlaylist = call.argument<Boolean>("isPlaylist") ?: false
                val isInstagram = call.argument<Boolean>("isInstagram") ?: false
                dispatchAsync(result, "EXTRACT_RAW_INFO_FAILED") {
                    unwrapEnvelopeResult(
                        AndroidDownloadEngine.extractRawInfo(
                            applicationContext,
                            url,
                            isPlaylist,
                            isInstagram,
                        ),
                    )
                }
            }

            "startDownload" -> {
                val requestJson = requireArg(call, result, "requestJson") ?: return
                ensureTransferPermissions(promptAllFilesIfMissing = true)
                dispatchAsync(result, "START_DOWNLOAD_FAILED") {
                    AndroidDownloadEngine.startDownload(applicationContext, requestJson)
                }
            }

            "cancelDownload" -> {
                val jobId = requireArg(call, result, "jobId") ?: return
                dispatchAsync(result, "CANCEL_DOWNLOAD_FAILED") {
                    AndroidDownloadEngine.cancelDownload(applicationContext, jobId)
                    null
                }
            }

            "resumeDownload" -> {
                val jobId = requireArg(call, result, "jobId") ?: return
                ensureTransferPermissions(promptAllFilesIfMissing = true)
                dispatchAsync(result, "RESUME_DOWNLOAD_FAILED") {
                    AndroidDownloadEngine.resumeDownload(applicationContext, jobId)
                }
            }

            "loadSavedPlaylistSession" -> {
                val playlistId = requireArg(call, result, "playlistId") ?: return
                dispatchAsync(result, "LOAD_SESSION_FAILED") {
                    AndroidDownloadEngine.loadSavedPlaylistSession(applicationContext, playlistId)
                }
            }

            "startPlaylistDownload" -> {
                val requestJson = requireArg(call, result, "requestJson") ?: return
                ensureTransferPermissions(promptAllFilesIfMissing = true)
                dispatchAsync(result, "START_PLAYLIST_FAILED") {
                    AndroidDownloadEngine.startPlaylistDownload(applicationContext, requestJson)
                }
            }

            "pausePlaylistDownload" -> {
                val sessionId = requireArg(call, result, "sessionId") ?: return
                dispatchAsync(result, "PAUSE_PLAYLIST_FAILED") {
                    AndroidDownloadEngine.pausePlaylistDownload(applicationContext, sessionId)
                    null
                }
            }

            "resumePlaylistDownload" -> {
                val sessionId = requireArg(call, result, "sessionId") ?: return
                ensureTransferPermissions(promptAllFilesIfMissing = true)
                dispatchAsync(result, "RESUME_PLAYLIST_FAILED") {
                    AndroidDownloadEngine.resumePlaylistDownload(applicationContext, sessionId)
                }
            }

            "cancelPlaylistDownload" -> {
                val sessionId = requireArg(call, result, "sessionId") ?: return
                dispatchAsync(result, "CANCEL_PLAYLIST_FAILED") {
                    AndroidDownloadEngine.cancelPlaylistDownload(applicationContext, sessionId)
                    null
                }
            }

            "retryFailedPlaylistItems" -> {
                val sessionId = requireArg(call, result, "sessionId") ?: return
                ensureTransferPermissions()
                dispatchAsync(result, "RETRY_PLAYLIST_FAILED") {
                    AndroidDownloadEngine.retryFailedPlaylistItems(applicationContext, sessionId)
                }
            }

            "openFile" -> {
                val path = requireArg(call, result, "path") ?: return
                result.success(AndroidMediaStoreExporter.openFile(this, path))
            }

            "revealInFolder" -> {
                val path = requireArg(call, result, "path") ?: return
                result.success(AndroidMediaStoreExporter.revealInFolder(this, path))
            }

            "shareFile" -> {
                val path = requireArg(call, result, "path") ?: return
                result.success(AndroidMediaStoreExporter.shareFile(this, path))
            }

            else -> result.notImplemented()
        }
    }

    private fun registerJsonEventChannel(
        messenger: io.flutter.plugin.common.BinaryMessenger,
        channelName: String,
        attach: (EventChannel.EventSink) -> Unit,
        detach: () -> Unit,
    ) {
        EventChannel(messenger, channelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    detach()
                }
            },
        )
    }

    private fun requireArg(
        call: MethodCall,
        result: MethodChannel.Result,
        key: String,
    ): String? {
        val value = call.argument<String>(key)
        if (value.isNullOrBlank()) {
            result.error("INVALID_ARGS", "Missing '$key' argument", null)
            return null
        }
        return value
    }

    private fun <T> dispatchAsync(
        result: MethodChannel.Result,
        errorCode: String,
        work: () -> T,
    ) {
        engineExecutor.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(errorCode, t.message ?: t.toString(), null)
                }
            }
        }
    }

    private fun unwrapEnvelopeResult(envelopeRaw: String): String {
        val envelope = JSONObject(envelopeRaw)
        if (envelope.has("error")) {
            throw IllegalStateException(envelope.optString("error").ifBlank { "Engine error" })
        }
        if (!envelope.has("ok")) {
            throw IllegalStateException("Malformed engine response")
        }
        return envelope.get("ok").toString()
    }

        private fun ensureTransferPermissions(promptAllFilesIfMissing: Boolean = false) {
            val missing = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    missing.add(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                if (ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    missing.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                }
            }
            if (missing.isNotEmpty()) {
                ActivityCompat.requestPermissions(this, missing.toTypedArray(), REQUEST_TRANSFER_PERMS)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                if (promptAllFilesIfMissing || !promptedAllFilesAccess) {
                    promptedAllFilesAccess = true
                    val manageIntent = Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName"),
                    )
                    val opened = runCatching {
                        startActivity(manageIntent)
                        true
                    }.getOrDefault(false)
                    if (!opened) {
                        runCatching {
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    }
                }
            }
        }

        private fun extractSharedUrl(intent: Intent?): String? {
            if (intent?.action != Intent.ACTION_SEND) {
                return null
            }
            val candidates = mutableListOf<String>()
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { candidates.add(it) }
            intent.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i)?.coerceToText(this)?.toString()?.let { candidates.add(it) }
                }
            }
            for (raw in candidates) {
                val match = URL_REGEX.find(raw) ?: continue
                val cleaned = match.value.trimEnd('.', ',', ';', ')', ']', '>', '"', '\'')
                if (cleaned.startsWith("http://") || cleaned.startsWith("https://")) {
                    return cleaned
                }
            }
            return null
        }

        private fun maybeRunPhaseAProof(intent: Intent?) {
            val isDebuggable =
                (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
            if (!isDebuggable || intent?.getBooleanExtra("phase_a_proof", false) != true) {
                return
            }
            val testUrl =
                intent.getStringExtra("proof_url") ?: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
            engineExecutor.execute {
                try {
                    Log.i(PROOF_TAG, "Starting Phase A runtime diagnostics...")
                    val diagJson = AndroidDownloadEngine.runDiagnostics(applicationContext)
                    Log.i(PROOF_TAG, "DIAGNOSTICS_JSON=$diagJson")

                    Log.i(PROOF_TAG, "Inspecting authorized test video: $testUrl")
                    val t0 = System.currentTimeMillis()
                    val inspectJson = AndroidDownloadEngine.extractRawInfo(
                        applicationContext,
                        testUrl,
                        isPlaylist = false,
                        isInstagram = false,
                    )
                    val elapsedMs = System.currentTimeMillis() - t0
                    val envelope = JSONObject(inspectJson)
                    if (envelope.has("ok")) {
                        val rawInfo = JSONObject(envelope.getString("ok"))
                        val summary = JSONObject().apply {
                            put("id", rawInfo.optString("id"))
                            put("title", rawInfo.optString("title"))
                            put("uploader", rawInfo.opt("uploader"))
                            put("extractor", rawInfo.optString("extractor_key"))
                            put("duration_seconds", rawInfo.opt("duration"))
                            put("inspect_elapsed_ms", elapsedMs)
                            put("formats_count", rawInfo.optJSONArray("formats")?.length() ?: 0)
                        }
                        Log.i(PROOF_TAG, "INSPECT_SUMMARY_JSON=$summary")
                    } else {
                        Log.e(PROOF_TAG, "INSPECT_ERROR_JSON=$inspectJson")
                    }
                } catch (t: Throwable) {
                    Log.e(PROOF_TAG, "PHASE_A_PROOF_EXCEPTION=${t.stackTraceToString()}")
                }
            }
        }

        override fun onDestroy() {
            engineExecutor.shutdownNow()
            super.onDestroy()
        }

        companion object {
            private const val PROOF_TAG = "HyperDownloadProof"
            private const val ENGINE_CHANNEL = "com.hyperdownload/media_engine"
            private const val PLATFORM_INTENT_CHANNEL = "com.hyperdownload/platform_intents"
            private const val DOWNLOAD_PROGRESS_CHANNEL = "com.hyperdownload/download_progress"
            private const val PLAYLIST_PROGRESS_CHANNEL = "com.hyperdownload/playlist_progress"
            private const val REQUEST_TRANSFER_PERMS = 9101
            private val URL_REGEX = Regex("https?://[^\\s<>\"']+")
        }
    }

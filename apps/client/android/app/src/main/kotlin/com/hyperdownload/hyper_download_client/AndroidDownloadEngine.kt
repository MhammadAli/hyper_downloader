package com.hyperdownload.hyper_download_client

import android.app.job.JobParameters
import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

fun interface PythonStringCallback {
    fun onEvent(json: String)
}

data class NotificationSummary(
    val title: String,
    val subtitle: String,
    val percent: Int?,
    val indeterminate: Boolean,
)

/**
 * Process-wide Android engine orchestrator bridging Kotlin with Chaquopy `hyperdl_worker`,
 * canonical Rust `libengine_ffi.so`, `MediaStore.Downloads`, and background transfer services.
 */
object AndroidDownloadEngine {
    private const val TAG = "AndroidDownloadEngine"
    private const val MANIFEST_FILENAME = ".hyperdl_playlist_session.json"
    private const val SINGLE_CHECKPOINT_FILE = "active_single_transfer.json"
    private const val PLAYLIST_POINTER_FILE = "active_playlist_pointer.json"

    private val pythonLock = Any()
    private val stateLock = Any()
    private val workerExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var downloadEventEmitter: ((String) -> Unit)? = null

    @Volatile
    private var playlistEventEmitter: ((String) -> Unit)? = null

    @Volatile
    private var sizeEstimateEventEmitter: ((String) -> Unit)? = null

    private var activeSingleJob: SingleJobRecord? = null
    private var activePlaylistSession: PlaylistRuntimeRecord? = null
    private var activeEstimationId: String? = null

    private var boundJobService: Pair<HyperDownloadJobService, JobParameters>? = null
    private var boundForegroundService: HyperDownloadForegroundService? = null

    private var lastNotificationMs = 0L
    private var lastCheckpointMs = 0L
    private var latestNotificationSummary = NotificationSummary(
        title = "HyperDownload",
        subtitle = "Preparing transfer...",
        percent = null,
        indeterminate = true,
    )

    private data class SingleJobRecord(
        val jobId: String,
        val requestJson: String,
        val title: String,
        val stagingDir: String,
        var isRunning: Boolean,
        var cancelRequested: Boolean = false,
        var downloadedBytes: Long = 0L,
        var totalBytes: Long? = null,
        var lastPhase: String = "Analyzing",
    )

    private data class PlaylistRuntimeRecord(
        var snapshot: JSONObject,
        var stagingDir: String,
        var stems: List<String>,
        var isRunning: Boolean,
        var stopMode: String? = null, // "pause" or "cancel"
        var activeItemJobId: String? = null,
    )

    fun setDownloadEventEmitter(emitter: ((String) -> Unit)?) {
        downloadEventEmitter = emitter
    }

    fun setPlaylistEventEmitter(emitter: ((String) -> Unit)?) {
        playlistEventEmitter = emitter
    }

    fun setSizeEstimateEventEmitter(emitter: ((String) -> Unit)?) {
        sizeEstimateEventEmitter = emitter
    }

    private fun ensurePython(context: Context): Python {
        synchronized(pythonLock) {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(context.applicationContext))
            }
            return Python.getInstance()
        }
    }

    private fun workerModule(context: Context): PyObject {
        return ensurePython(context).getModule("hyperdl_worker")
    }

    fun nativeLibDir(context: Context): String {
        return context.applicationContext.applicationInfo.nativeLibraryDir
    }

    fun binDir(context: Context): String {
        val dir = File(context.applicationContext.filesDir, "bin")
        dir.mkdirs()
        return dir.absolutePath
    }

    fun cacheDir(context: Context): String {
        val dir = File(context.applicationContext.cacheDir, "yt_dlp_cache")
        dir.mkdirs()
        return dir.absolutePath
    }

    private fun stagingBaseDir(context: Context): File {
        val ext = context.applicationContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: context.applicationContext.filesDir
        return File(ext, "staging").apply { mkdirs() }
    }

    private fun checkpointsDir(context: Context): File {
        return File(context.applicationContext.filesDir, "checkpoints").apply { mkdirs() }
    }

    fun runDiagnostics(context: Context): String {
        val appCtx = context.applicationContext
        return workerModule(appCtx)
            .callAttr("run_diagnostics", nativeLibDir(appCtx), binDir(appCtx))
            .toString()
    }

    fun inspectUrl(context: Context, url: String): String {
        val appCtx = context.applicationContext
        return workerModule(appCtx)
            .callAttr("inspect_url", url, nativeLibDir(appCtx), binDir(appCtx), cacheDir(appCtx))
            .toString()
    }

    fun inspectMedia(context: Context, url: String): String {
        val appCtx = context.applicationContext
        return workerModule(appCtx)
            .callAttr("inspect_media", url, nativeLibDir(appCtx), binDir(appCtx), cacheDir(appCtx))
            .toString()
    }

    fun inspectPlaylist(context: Context, url: String): String {
        val appCtx = context.applicationContext
        return workerModule(appCtx)
            .callAttr(
                "inspect_playlist",
                url,
                nativeLibDir(appCtx),
                binDir(appCtx),
                cacheDir(appCtx),
            )
            .toString()
    }

    fun startDownload(context: Context, requestJson: String): String {
        val appCtx = context.applicationContext
        synchronized(stateLock) {
            if (activeSingleJob?.isRunning == true) {
                throw IllegalStateException("Another download is already running.")
            }
            if (activePlaylistSession?.isRunning == true) {
                throw IllegalStateException("A playlist download is already in progress.")
            }
        }

        val reqObj = JSONObject(requestJson)
        val title = reqObj.optString("title").takeIf { it.isNotBlank() } ?: "Media Download"
        val jobId = UUID.randomUUID().toString()
        val stagingDir = File(stagingBaseDir(appCtx), "single_$jobId").apply { mkdirs() }

        val record = SingleJobRecord(
            jobId = jobId,
            requestJson = requestJson,
            title = title,
            stagingDir = stagingDir.absolutePath,
            isRunning = true,
        )
        synchronized(stateLock) {
            activeSingleJob = record
        }
        persistSingleCheckpoint(appCtx, record, "running")
        latestNotificationSummary = NotificationSummary(
            title = title,
            subtitle = "Preparing download...",
            percent = null,
            indeterminate = true,
        )
        HyperDownloadTransferScheduler.scheduleTransferExecution(appCtx, null)
        launchSingleWorker(appCtx, record)
        return jobId
    }

    fun cancelDownload(context: Context, jobId: String) {
        val appCtx = context.applicationContext
        val record = synchronized(stateLock) {
            val current = activeSingleJob
            if (current == null || current.jobId != jobId) {
                throw IllegalStateException("Download job '$jobId' not found.")
            }
            if (!current.isRunning) {
                throw IllegalStateException("Download job '$jobId' is not currently running.")
            }
            current.cancelRequested = true
            current
        }
        runCatching { workerModule(appCtx).callAttr("cancel_job", record.jobId) }
    }

    fun resumeDownload(context: Context, jobId: String): String {
        val appCtx = context.applicationContext
        val record = synchronized(stateLock) {
            val current = activeSingleJob
                ?: throw IllegalStateException("Download job '$jobId' not found.")
            if (current.jobId != jobId) {
                throw IllegalStateException("Download job '$jobId' not found.")
            }
            if (current.isRunning) {
                throw IllegalStateException("Download job '$jobId' is already running.")
            }
            current.isRunning = true
            current.cancelRequested = false
            current
        }
        persistSingleCheckpoint(appCtx, record, "running")
        latestNotificationSummary = NotificationSummary(
            title = record.title,
            subtitle = "Resuming download...",
            percent = null,
            indeterminate = true,
        )
        HyperDownloadTransferScheduler.scheduleTransferExecution(appCtx, record.totalBytes)
        launchSingleWorker(appCtx, record)
        return record.jobId
    }

    private fun launchSingleWorker(appCtx: Context, record: SingleJobRecord) {
        workerExecutor.execute {
            val cb = PythonStringCallback { eventJson ->
                val obj = runCatching { JSONObject(eventJson) }.getOrNull()
                if (obj != null) {
                    val phase = obj.optString("phase")
                    val down = obj.optLong("downloaded_bytes", 0L)
                    val total = if (obj.isNull("total_bytes")) null else obj.optLong("total_bytes")
                    val speed = if (obj.isNull("speed_bytes_per_sec")) null else obj.optDouble("speed_bytes_per_sec")
                    synchronized(stateLock) {
                        record.downloadedBytes = down
                        if (total != null) record.totalBytes = total
                        record.lastPhase = phase
                    }
                    maybeCheckpointSingle(appCtx, record, phase)
                    maybeUpdateSingleNotification(appCtx, record.title, phase, down, total, speed)
                }
                emitDownloadEvent(eventJson)
            }

            val rawResult = runCatching {
                workerModule(appCtx).callAttr(
                    "execute_single_download",
                    record.jobId,
                    record.requestJson,
                    record.stagingDir,
                    nativeLibDir(appCtx),
                    binDir(appCtx),
                    cacheDir(appCtx),
                    cb,
                ).toString()
            }.getOrElse { err ->
                JSONObject().put("error", err.message ?: err.toString()).toString()
            }

            val resultObj = runCatching { JSONObject(rawResult) }.getOrElse {
                JSONObject().put("error", "Invalid worker response")
            }

            val wasCanceled = resultObj.optBoolean("canceled", false) || record.cancelRequested
            if (wasCanceled) {
                val dl = resultObj.optLong("downloaded_bytes", record.downloadedBytes)
                val tot = if (resultObj.isNull("total_bytes")) record.totalBytes else resultObj.optLong("total_bytes")
                val est = resultObj.optBoolean("is_total_estimated", false)
                synchronized(stateLock) {
                    record.isRunning = false
                    record.lastPhase = "Canceled"
                }
                persistSingleCheckpoint(appCtx, record, "canceled")
                emitDownloadEvent(
                    JSONObject().apply {
                        put("job_id", record.jobId)
                        put("phase", "Canceled")
                        put("downloaded_bytes", dl)
                        put("total_bytes", tot ?: JSONObject.NULL)
                        put("is_total_estimated", est)
                        put("speed_bytes_per_sec", JSONObject.NULL)
                        put("eta_seconds", JSONObject.NULL)
                        put("output_path", JSONObject.NULL)
                        put("message", "Download canceled. Partial data preserved for resume.")
                    }.toString(),
                )
                TransferNotificationManager.clearProgressNotification(appCtx)
                notifyIdleIfNoWork(appCtx)
                return@execute
            }

            if (resultObj.has("ok")) {
                val ok = resultObj.getJSONObject("ok")
                val stagedPath = ok.getString("output_path")
                val stagedFile = File(stagedPath)
                try {
                    val reqObj = JSONObject(record.requestJson)
                    val title = reqObj.optString("title").takeIf { it.isNotBlank() }
                        ?: stagedFile.nameWithoutExtension
                    val ext = stagedFile.extension.ifBlank { "mp4" }
                    val safeFileName = "${AndroidMediaStoreExporter.sanitizeSegment(title, 110)}.$ext"
                    val exported = AndroidMediaStoreExporter.exportFile(
                        context = appCtx,
                        stagedFile = stagedFile,
                        desiredFileName = safeFileName,
                        playlistSubfolder = null,
                    )
                    runCatching { File(record.stagingDir).deleteRecursively() }
                    synchronized(stateLock) {
                        record.isRunning = false
                        record.downloadedBytes = exported.verifiedBytes
                        record.totalBytes = exported.verifiedBytes
                        record.lastPhase = "Completed"
                    }
                    clearSingleCheckpoint(appCtx)
                    emitDownloadEvent(
                        JSONObject().apply {
                            put("job_id", record.jobId)
                            put("phase", "Completed")
                            put("downloaded_bytes", exported.verifiedBytes)
                            put("total_bytes", exported.verifiedBytes)
                            put("is_total_estimated", false)
                            put("speed_bytes_per_sec", JSONObject.NULL)
                            put("eta_seconds", 0)
                            put("output_path", exported.displayPath)
                            put("message", "Saved to Downloads/HyperDownload.")
                        }.toString(),
                    )
                    TransferNotificationManager.clearProgressNotification(appCtx)
                    TransferNotificationManager.showTerminalNotification(
                        context = appCtx,
                        title = "Download completed",
                        contentText = safeFileName,
                        isError = false,
                    )
                } catch (exportErr: Throwable) {
                    synchronized(stateLock) {
                        record.isRunning = false
                        record.lastPhase = "Failed"
                    }
                    persistSingleCheckpoint(appCtx, record, "failed")
                    val msg = "MediaStore export failed: ${exportErr.message ?: exportErr}"
                    emitDownloadEvent(
                        JSONObject().apply {
                            put("job_id", record.jobId)
                            put("phase", "Failed")
                            put("downloaded_bytes", record.downloadedBytes)
                            put("total_bytes", record.totalBytes ?: JSONObject.NULL)
                            put("is_total_estimated", false)
                            put("speed_bytes_per_sec", JSONObject.NULL)
                            put("eta_seconds", JSONObject.NULL)
                            put("output_path", JSONObject.NULL)
                            put("message", msg)
                        }.toString(),
                    )
                    TransferNotificationManager.clearProgressNotification(appCtx)
                    TransferNotificationManager.showTerminalNotification(
                        context = appCtx,
                        title = "Download failed",
                        contentText = msg,
                        isError = true,
                    )
                }
            } else {
                val errMsg = resultObj.optString("error", "Download failed")
                val dl = resultObj.optLong("downloaded_bytes", record.downloadedBytes)
                val tot = if (resultObj.isNull("total_bytes")) record.totalBytes else resultObj.optLong("total_bytes")
                val est = resultObj.optBoolean("is_total_estimated", false)
                synchronized(stateLock) {
                    record.isRunning = false
                    record.lastPhase = "Failed"
                }
                persistSingleCheckpoint(appCtx, record, "failed")
                emitDownloadEvent(
                    JSONObject().apply {
                        put("job_id", record.jobId)
                        put("phase", "Failed")
                        put("downloaded_bytes", dl)
                        put("total_bytes", tot ?: JSONObject.NULL)
                        put("is_total_estimated", est)
                        put("speed_bytes_per_sec", JSONObject.NULL)
                        put("eta_seconds", JSONObject.NULL)
                        put("output_path", JSONObject.NULL)
                        put("message", errMsg)
                    }.toString(),
                )
                TransferNotificationManager.clearProgressNotification(appCtx)
                TransferNotificationManager.showTerminalNotification(
                    context = appCtx,
                    title = "Download failed",
                    contentText = errMsg,
                    isError = true,
                )
            }
            notifyIdleIfNoWork(appCtx)
        }
    }

    fun estimatePlaylistSize(context: Context, requestJson: String): String {
        val appCtx = context.applicationContext
        val previousId = synchronized(stateLock) {
            val prev = activeEstimationId
            val newId = UUID.randomUUID().toString()
            activeEstimationId = newId
            prev to newId
        }
        if (previousId.first != null) {
            runCatching {
                workerModule(appCtx).callAttr("cancel_size_estimation", previousId.first)
            }
        }
        val estimationId = previousId.second
        val reqObj = JSONObject(requestJson)
        val playlist = reqObj.getJSONObject("playlist")
        val mediaMode = reqObj.getString("media_mode")
        val qualityCap = reqObj.getString("quality_cap")
        val entries = playlist.optJSONArray("entries") ?: JSONArray()

        // First build initial snapshot quickly by checking cached items or launching async worker.
        val initialResultRef = AtomicReference<String?>(null)
        val initialReady = java.util.concurrent.CountDownLatch(1)
        val startedSync = AtomicBoolean(false)

        val cb = PythonStringCallback { estJson ->
            if (startedSync.compareAndSet(false, true)) {
                initialResultRef.set(estJson)
                initialReady.countDown()
            }
            emitSizeEstimateEvent(estJson)
        }

        workerExecutor.execute {
            val resRaw = runCatching {
                workerModule(appCtx).callAttr(
                    "estimate_playlist_size",
                    estimationId,
                    requestJson,
                    nativeLibDir(appCtx),
                    binDir(appCtx),
                    cacheDir(appCtx),
                    cb,
                ).toString()
            }.getOrElse { err ->
                JSONObject().put("error", err.message ?: err.toString()).toString()
            }

            if (startedSync.compareAndSet(false, true)) {
                val parsed = runCatching { JSONObject(resRaw) }.getOrNull()
                if (parsed != null && parsed.has("ok")) {
                    initialResultRef.set(parsed.getJSONObject("ok").toString())
                } else {
                    val errMsg = parsed?.optString("error") ?: "Failed to calculate playlist size."
                    val unavailable = (0 until entries.length()).count { idx ->
                        entries.getJSONObject(idx).optString("availability") != "Available"
                    }
                    val eligible = entries.length() - unavailable
                    val failSnap = JSONObject().apply {
                        put("estimation_id", estimationId)
                        put("playlist_id", playlist.optString("id"))
                        put("media_mode", mediaMode)
                        put("quality_cap", qualityCap)
                        put("status", "Failed")
                        put("known_total_bytes", 0)
                        put("total_entries_count", entries.length())
                        put("unavailable_count", unavailable)
                        put("eligible_count", eligible)
                        put("inspected_count", 0)
                        put("exact_count", 0)
                        put("estimated_count", 0)
                        put("unknown_count", 0)
                        put("failed_count", eligible)
                        put("display_summary", "Some video sizes could not be determined")
                        put("status_message", errMsg)
                        put("item_sizes", JSONArray())
                    }.toString()
                    initialResultRef.set(failSnap)
                    emitSizeEstimateEvent(failSnap)
                }
                initialReady.countDown()
            }
        }

        initialReady.await()
        return initialResultRef.get()
            ?: throw IllegalStateException("Size estimation produced no initial snapshot.")
    }

    fun cancelPlaylistSizeEstimation(context: Context, estimationId: String) {
        val appCtx = context.applicationContext
        runCatching { workerModule(appCtx).callAttr("cancel_size_estimation", estimationId) }
    }

    fun loadSavedPlaylistSession(context: Context, playlistId: String): String? {
        val appCtx = context.applicationContext
        val playlistsRoot = File(stagingBaseDir(appCtx), "playlists")
        if (!playlistsRoot.isDirectory) return null
        val subdirs = playlistsRoot.listFiles() ?: return null
        for (dir in subdirs) {
            if (!dir.isDirectory) continue
            val manifestFile = File(dir, MANIFEST_FILENAME)
            if (!manifestFile.isFile) continue
            val snap = runCatching { JSONObject(manifestFile.readText()) }.getOrNull() ?: continue
            if (snap.optString("playlist_id") != playlistId) continue

            reconcilePlaylistSnapshot(appCtx, snap)
            synchronized(stateLock) {
                val runningNow = activePlaylistSession?.isRunning == true
                if (!runningNow) {
                    activePlaylistSession = PlaylistRuntimeRecord(
                        snapshot = snap,
                        stagingDir = dir.absolutePath,
                        stems = computeStemsForItems(snap.getJSONArray("items")),
                        isRunning = false,
                    )
                }
            }
            return snap.toString()
        }
        return null
    }

    fun startPlaylistDownload(context: Context, requestJson: String): String {
        val appCtx = context.applicationContext
        synchronized(stateLock) {
            if (activeSingleJob?.isRunning == true || activePlaylistSession?.isRunning == true) {
                throw IllegalStateException("Another download is already running.")
            }
        }

        val reqObj = JSONObject(requestJson)
        val playlist = reqObj.getJSONObject("playlist")
        val entries = playlist.optJSONArray("entries") ?: JSONArray()
        if (entries.length() == 0) {
            throw IllegalArgumentException("Playlist contains zero entries to download.")
        }

        val mediaMode = reqObj.getString("media_mode")
        val qualityCap = reqObj.getString("quality_cap")
        val playlistId = playlist.getString("id")
        val playlistTitle = playlist.getString("title")

        val folderName = playlistFolderName(playlistTitle, playlistId)
        val stagingDir = File(File(stagingBaseDir(appCtx), "playlists"), folderName).apply {
            mkdirs()
        }
        val displayOutputDir = "/storage/emulated/0/${Environment.DIRECTORY_DOWNLOADS}/HyperDownload/$folderName"

        val previousManifest = File(stagingDir, MANIFEST_FILENAME).takeIf { it.isFile }?.let {
            runCatching { JSONObject(it.readText()) }.getOrNull()
        }
        val reuseCompleted = previousManifest != null &&
            previousManifest.optString("media_mode") == mediaMode &&
            previousManifest.optString("quality_cap") == qualityCap

        val itemsArray = JSONArray()
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            val availability = entry.optString("availability")
            val orderIdx = entry.getInt("order_index")
            val videoId = entry.getString("video_id")

            var chosenItem: JSONObject? = null
            if (availability != "Available") {
                chosenItem = JSONObject().apply {
                    put("order_index", orderIdx)
                    put("video_id", videoId)
                    put("title", entry.getString("title"))
                    put("url", entry.getString("url"))
                    put("duration_seconds", entry.opt("duration_seconds") ?: JSONObject.NULL)
                    put("thumbnail_url", entry.opt("thumbnail_url") ?: JSONObject.NULL)
                    put("status", "Skipped")
                    put("selected_quality", JSONObject.NULL)
                    put("audio_language", JSONObject.NULL)
                    put("downloaded_bytes", 0)
                    put("total_bytes", JSONObject.NULL)
                    put("is_total_estimated", false)
                    put("output_path", JSONObject.NULL)
                    put("error_message", entry.opt("availability_reason") ?: JSONObject.NULL)
                }
            } else if (reuseCompleted && previousManifest != null) {
                val prevItems = previousManifest.optJSONArray("items") ?: JSONArray()
                for (j in 0 until prevItems.length()) {
                    val prev = prevItems.getJSONObject(j)
                    if (prev.optString("video_id") == videoId &&
                        prev.optInt("order_index") == orderIdx &&
                        prev.optString("status") == "Completed" &&
                        AndroidMediaStoreExporter.existsExported(
                            appCtx,
                            prev.optString("output_path").takeIf { it.isNotBlank() },
                        )
                    ) {
                        chosenItem = JSONObject(prev.toString())
                        break
                    }
                }
            }

            if (chosenItem == null) {
                chosenItem = JSONObject().apply {
                    put("order_index", orderIdx)
                    put("video_id", videoId)
                    put("title", entry.getString("title"))
                    put("url", entry.getString("url"))
                    put("duration_seconds", entry.opt("duration_seconds") ?: JSONObject.NULL)
                    put("thumbnail_url", entry.opt("thumbnail_url") ?: JSONObject.NULL)
                    put("status", "Pending")
                    put("selected_quality", JSONObject.NULL)
                    put("audio_language", JSONObject.NULL)
                    put("downloaded_bytes", 0)
                    put("total_bytes", JSONObject.NULL)
                    put("is_total_estimated", false)
                    put("output_path", JSONObject.NULL)
                    put("error_message", JSONObject.NULL)
                }
            }
            itemsArray.put(chosenItem)
        }

        val sessionId = UUID.randomUUID().toString()
        val snap = JSONObject().apply {
            put("session_id", sessionId)
            put("playlist_id", playlistId)
            put("playlist_title", playlistTitle)
            put("playlist_url", playlist.getString("webpage_url"))
            put("uploader", playlist.opt("uploader") ?: JSONObject.NULL)
            put("thumbnail_url", playlist.opt("thumbnail_url") ?: JSONObject.NULL)
            put("output_directory", displayOutputDir)
            put("media_mode", mediaMode)
            put("quality_cap", qualityCap)
            put("is_running", true)
            put("is_paused", false)
            put("completed_count", 0)
            put("failed_count", 0)
            put("skipped_count", 0)
            put("total_count", itemsArray.length())
            put("items", itemsArray)
        }
        recomputePlaylistCounters(snap)
        saveManifestAtomic(stagingDir, snap)

        val record = PlaylistRuntimeRecord(
            snapshot = snap,
            stagingDir = stagingDir.absolutePath,
            stems = computeStemsForItems(itemsArray),
            isRunning = true,
        )
        synchronized(stateLock) {
            activePlaylistSession = record
        }
        persistPlaylistPointer(appCtx, record)
        launchPlaylistWorker(appCtx, record)
        return snap.toString()
    }

    fun pausePlaylistDownload(context: Context, sessionId: String) {
        requestPlaylistStop(context.applicationContext, sessionId, "pause")
    }

    fun cancelPlaylistDownload(context: Context, sessionId: String) {
        requestPlaylistStop(context.applicationContext, sessionId, "cancel")
    }

    fun resumePlaylistDownload(context: Context, sessionId: String): String {
        val appCtx = context.applicationContext
        val record = synchronized(stateLock) {
            val active = activePlaylistSession
                ?: throw IllegalStateException("Playlist session '$sessionId' not found.")
            if (active.snapshot.getString("session_id") != sessionId) {
                throw IllegalStateException("Playlist session '$sessionId' not found.")
            }
            if (active.isRunning) {
                throw IllegalStateException("Playlist session '$sessionId' is already running.")
            }
            active.stopMode = null
            active.snapshot.put("is_paused", false)
            val items = active.snapshot.getJSONArray("items")
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                if (item.optString("status") == "Canceled") {
                    item.put("status", "Pending")
                    item.put("error_message", JSONObject.NULL)
                }
            }
            reconcilePlaylistSnapshot(appCtx, active.snapshot)
            active.snapshot.put("is_running", true)
            active.isRunning = true
            active
        }
        saveManifestAtomic(File(record.stagingDir), record.snapshot)
        persistPlaylistPointer(appCtx, record)
        launchPlaylistWorker(appCtx, record)
        return record.snapshot.toString()
    }

    fun retryFailedPlaylistItems(context: Context, sessionId: String): String {
        val appCtx = context.applicationContext
        val record = synchronized(stateLock) {
            val active = activePlaylistSession
                ?: throw IllegalStateException("Playlist session '$sessionId' not found.")
            if (active.snapshot.getString("session_id") != sessionId) {
                throw IllegalStateException("Playlist session '$sessionId' not found.")
            }
            if (active.isRunning) {
                throw IllegalStateException("Playlist session '$sessionId' is already running.")
            }
            val items = active.snapshot.getJSONArray("items")
            var failedCnt = 0
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                if (item.optString("status") == "Failed") {
                    item.put("status", "Pending")
                    item.put("error_message", JSONObject.NULL)
                    item.put("downloaded_bytes", 0)
                    item.put("total_bytes", JSONObject.NULL)
                    failedCnt++
                }
            }
            if (failedCnt == 0) {
                throw IllegalStateException("There are no failed playlist items to retry.")
            }
            active.stopMode = null
            active.snapshot.put("is_paused", false)
            active.snapshot.put("is_running", true)
            recomputePlaylistCounters(active.snapshot)
            active.isRunning = true
            active
        }
        saveManifestAtomic(File(record.stagingDir), record.snapshot)
        persistPlaylistPointer(appCtx, record)
        launchPlaylistWorker(appCtx, record)
        return record.snapshot.toString()
    }

    private fun requestPlaylistStop(appCtx: Context, sessionId: String, mode: String) {
        val activeJobId = synchronized(stateLock) {
            val active = activePlaylistSession
                ?: throw IllegalStateException("Playlist session '$sessionId' not found.")
            if (active.snapshot.getString("session_id") != sessionId) {
                throw IllegalStateException("Playlist session '$sessionId' not found.")
            }
            if (!active.isRunning) {
                throw IllegalStateException("Playlist session '$sessionId' is not currently running.")
            }
            active.stopMode = mode
            active.activeItemJobId
        }
        if (activeJobId != null) {
            runCatching { workerModule(appCtx).callAttr("cancel_job", activeJobId) }
        }
    }

    private fun launchPlaylistWorker(appCtx: Context, record: PlaylistRuntimeRecord) {
        val playlistTitle = record.snapshot.getString("playlist_title")
        val totalCount = record.snapshot.getInt("total_count")
        latestNotificationSummary = NotificationSummary(
            title = playlistTitle,
            subtitle = "Starting playlist (0 / $totalCount)...",
            percent = 0,
            indeterminate = false,
        )
        HyperDownloadTransferScheduler.scheduleTransferExecution(appCtx, null)

        emitPlaylistEvent(
            makePlaylistBatchEvent(
                record.snapshot,
                "PlaylistStarted",
                "Starting playlist '$playlistTitle' ($totalCount items)...",
            ),
        )

        workerExecutor.execute {
            val items = record.snapshot.getJSONArray("items")
            val folderName = File(record.stagingDir).name
            var stoppedBy: String? = null

            for (idx in 0 until items.length()) {
                val stopCheck = synchronized(stateLock) { record.stopMode }
                if (stopCheck != null) {
                    stoppedBy = stopCheck
                    break
                }

                val item = items.getJSONObject(idx)
                val status = item.optString("status")
                if (status == "Completed") {
                    continue
                }
                if (status == "Skipped") {
                    emitPlaylistEvent(
                        makePlaylistItemEvent(
                            snap = record.snapshot,
                            kind = "PlaylistItemSkipped",
                            itemIndex = idx,
                            itemStatus = "Skipped",
                            selectedQuality = null,
                            audioLanguage = item.opt("audio_language"),
                            message = item.optString("error_message").takeIf { it.isNotBlank() },
                        ),
                    )
                    continue
                }
                if (status != "Pending") {
                    continue
                }

                synchronized(stateLock) {
                    item.put("status", "Analyzing")
                    item.put("error_message", JSONObject.NULL)
                    recomputePlaylistCounters(record.snapshot)
                }
                saveManifestAtomic(File(record.stagingDir), record.snapshot)
                persistPlaylistPointer(appCtx, record)

                val itemTitle = item.getString("title")
                emitPlaylistEvent(
                    makePlaylistItemEvent(
                        snap = record.snapshot,
                        kind = "PlaylistItemStarted",
                        itemIndex = idx,
                        itemStatus = "Analyzing",
                        selectedQuality = null,
                        audioLanguage = null,
                        message = "Analyzing '$itemTitle'...",
                    ),
                )
                updatePlaylistNotification(appCtx, record.snapshot, "Analyzing: $itemTitle")

                val inspectRaw = runCatching {
                    workerModule(appCtx).callAttr(
                        "inspect_media_cached",
                        item.getString("video_id"),
                        item.getString("url"),
                        nativeLibDir(appCtx),
                        binDir(appCtx),
                        cacheDir(appCtx),
                    ).toString()
                }.getOrElse { err ->
                    JSONObject().put("error", err.message ?: err.toString()).toString()
                }

                val stopAfterInspect = synchronized(stateLock) { record.stopMode }
                if (stopAfterInspect != null) {
                    revertInterruptedPlaylistItem(record, idx, stopAfterInspect)
                    stoppedBy = stopAfterInspect
                    break
                }

                val inspectObj = runCatching { JSONObject(inspectRaw) }.getOrNull()
                if (inspectObj == null || inspectObj.has("error")) {
                    val errMsg = inspectObj?.optString("error") ?: "Inspection failed."
                    recordPlaylistItemFailure(appCtx, record, idx, errMsg)
                    continue
                }

                val mediaObj = inspectObj.getJSONObject("ok")
                val resolvedRaw = runCatching {
                    workerModule(appCtx).callAttr(
                        "select_playlist_item_option",
                        mediaObj.toString(),
                        record.snapshot.getString("media_mode"),
                        record.snapshot.getString("quality_cap"),
                        nativeLibDir(appCtx),
                    ).toString()
                }.getOrElse { err ->
                    JSONObject().put("error", err.message ?: err.toString()).toString()
                }

                val resolvedObj = runCatching { JSONObject(resolvedRaw) }.getOrNull()
                if (resolvedObj == null || resolvedObj.has("error")) {
                    val errMsg = resolvedObj?.optString("error") ?: "No compatible format found."
                    recordPlaylistItemFailure(appCtx, record, idx, errMsg)
                    continue
                }

                val resolved = resolvedObj.getJSONObject("ok")
                val qualityLabel = resolved.getString("quality_label")
                val audioLanguage = resolved.opt("audio_language")
                val selection = resolved.getJSONObject("selection")

                synchronized(stateLock) {
                    item.put("status", "Downloading")
                    item.put("selected_quality", qualityLabel)
                    if (audioLanguage != null) item.put("audio_language", audioLanguage)
                }

                val stem = record.stems.getOrElse(idx) {
                    "${(idx + 1).toString().padStart(3, '0')} - ${
                        AndroidMediaStoreExporter.sanitizeSegment(itemTitle, 90)
                    }"
                }
                val itemJobId = "${record.snapshot.getString("session_id")}_$idx"
                synchronized(stateLock) {
                    record.activeItemJobId = itemJobId
                }

                val itemStagingDir = File(record.stagingDir, "item_$idx").apply { mkdirs() }
                val outtmpl = File(itemStagingDir, "$stem.%(ext)s").absolutePath
                val dlReq = JSONObject().apply {
                    put(
                        "url",
                        mediaObj.optString("webpage_url").takeIf { it.isNotBlank() }
                            ?: item.getString("url"),
                    )
                    put("title", itemTitle)
                    put("selection", selection)
                    put("output_template", outtmpl)
                }

                val progressCb = PythonStringCallback { evJson ->
                    val ev = runCatching { JSONObject(evJson) }.getOrNull() ?: return@PythonStringCallback
                    val phase = ev.optString("phase")
                    if (phase == "Analyzing" || phase == "Canceled" || phase == "Failed") return@PythonStringCallback

                    val isMerging = phase == "Merging"
                    val down = ev.optLong("downloaded_bytes", 0L)
                    val tot = if (ev.isNull("total_bytes")) null else ev.optLong("total_bytes")
                    val est = ev.optBoolean("is_total_estimated", false)
                    val speed = if (ev.isNull("speed_bytes_per_sec")) null else ev.optDouble("speed_bytes_per_sec")
                    val eta = if (ev.isNull("eta_seconds")) null else ev.optLong("eta_seconds")

                    synchronized(stateLock) {
                        item.put("status", if (isMerging) "Merging" else "Downloading")
                        item.put("downloaded_bytes", down)
                        if (tot != null) item.put("total_bytes", tot)
                        item.put("is_total_estimated", est)
                    }

                    emitPlaylistEvent(
                        JSONObject().apply {
                            put("session_id", record.snapshot.getString("session_id"))
                            put("kind", if (isMerging) "PlaylistItemMerging" else "PlaylistItemProgress")
                            put("item_index", idx)
                            put("item_status", if (isMerging) "Merging" else "Downloading")
                            put("selected_quality", qualityLabel)
                            put("audio_language", audioLanguage ?: JSONObject.NULL)
                            put("item_downloaded_bytes", down)
                            put("item_total_bytes", tot ?: JSONObject.NULL)
                            put("item_is_total_estimated", est)
                            put("speed_bytes_per_sec", speed ?: JSONObject.NULL)
                            put("eta_seconds", eta ?: JSONObject.NULL)
                            put("output_path", JSONObject.NULL)
                            put("completed_count", record.snapshot.getInt("completed_count"))
                            put("failed_count", record.snapshot.getInt("failed_count"))
                            put("skipped_count", record.snapshot.getInt("skipped_count"))
                            put("total_count", record.snapshot.getInt("total_count"))
                            put("playlist_output_dir", record.snapshot.getString("output_directory"))
                            put("message", ev.opt("message") ?: JSONObject.NULL)
                        }.toString(),
                    )
                    updatePlaylistNotification(
                        appCtx,
                        record.snapshot,
                        if (isMerging) "Merging: $itemTitle" else "Downloading: $itemTitle",
                    )
                }

                val dlRaw = runCatching {
                    workerModule(appCtx).callAttr(
                        "execute_single_download",
                        itemJobId,
                        dlReq.toString(),
                        itemStagingDir.absolutePath,
                        nativeLibDir(appCtx),
                        binDir(appCtx),
                        cacheDir(appCtx),
                        progressCb,
                    ).toString()
                }.getOrElse { err ->
                    JSONObject().put("error", err.message ?: err.toString()).toString()
                }

                synchronized(stateLock) {
                    record.activeItemJobId = null
                }

                val stopAfterDl = synchronized(stateLock) { record.stopMode }
                if (stopAfterDl != null) {
                    revertInterruptedPlaylistItem(record, idx, stopAfterDl)
                    stoppedBy = stopAfterDl
                    break
                }

                val dlRes = runCatching { JSONObject(dlRaw) }.getOrNull()
                if (dlRes != null && dlRes.has("ok")) {
                    val stagedPath = dlRes.getJSONObject("ok").getString("output_path")
                    val stagedFile = File(stagedPath)
                    try {
                        val ext = stagedFile.extension.ifBlank { "mp4" }
                        val exported = AndroidMediaStoreExporter.exportFile(
                            context = appCtx,
                            stagedFile = stagedFile,
                            desiredFileName = "$stem.$ext",
                            playlistSubfolder = folderName,
                        )
                        runCatching { itemStagingDir.deleteRecursively() }
                        synchronized(stateLock) {
                            item.put("status", "Completed")
                            item.put("output_path", exported.displayPath)
                            item.put("downloaded_bytes", exported.verifiedBytes)
                            item.put("total_bytes", exported.verifiedBytes)
                            item.put("is_total_estimated", false)
                            item.put("error_message", JSONObject.NULL)
                            recomputePlaylistCounters(record.snapshot)
                        }
                        saveManifestAtomic(File(record.stagingDir), record.snapshot)
                        persistPlaylistPointer(appCtx, record)

                        val ev = JSONObject(
                            makePlaylistItemEvent(
                                snap = record.snapshot,
                                kind = "PlaylistItemCompleted",
                                itemIndex = idx,
                                itemStatus = "Completed",
                                selectedQuality = qualityLabel,
                                audioLanguage = audioLanguage,
                                message = "Item completed.",
                            ),
                        ).apply {
                            put("output_path", exported.displayPath)
                            put("item_downloaded_bytes", exported.verifiedBytes)
                            put("item_total_bytes", exported.verifiedBytes)
                        }
                        emitPlaylistEvent(ev.toString())
                    } catch (exportErr: Throwable) {
                        recordPlaylistItemFailure(
                            appCtx,
                            record,
                            idx,
                            "Export failed: ${exportErr.message ?: exportErr}",
                        )
                    }
                } else {
                    val errMsg = dlRes?.optString("error") ?: "Item download failed."
                    recordPlaylistItemFailure(appCtx, record, idx, errMsg)
                }
            }

            synchronized(stateLock) {
                record.isRunning = false
                record.snapshot.put("is_running", false)
                record.snapshot.put("is_paused", stoppedBy == "pause")
                record.stopMode = null
                recomputePlaylistCounters(record.snapshot)
            }
            saveManifestAtomic(File(record.stagingDir), record.snapshot)
            persistPlaylistPointer(appCtx, record)

            val (eventKind, msg) = when (stoppedBy) {
                "pause" -> "PlaylistPaused" to
                    "Playlist paused. Completed files preserved; tap Resume to continue."
                "cancel" -> "PlaylistCanceled" to
                    "Playlist canceled. Completed files preserved in Downloads/HyperDownload."
                else -> "PlaylistCompleted" to
                    "Playlist finished: ${record.snapshot.getInt("completed_count")} completed, ${
                        record.snapshot.getInt("failed_count")
                    } failed, ${record.snapshot.getInt("skipped_count")} skipped."
            }

            emitPlaylistEvent(makePlaylistBatchEvent(record.snapshot, eventKind, msg))
            TransferNotificationManager.clearProgressNotification(appCtx)
            if (stoppedBy == null) {
                val failed = record.snapshot.getInt("failed_count")
                TransferNotificationManager.showTerminalNotification(
                    context = appCtx,
                    title = if (failed > 0) "Playlist finished with $failed failed" else "Playlist completed",
                    contentText = "${record.snapshot.getString("playlist_title")} (${
                        record.snapshot.getInt("completed_count")
                    }/${record.snapshot.getInt("total_count")})",
                    isError = failed > 0 && record.snapshot.getInt("completed_count") == 0,
                )
            }
            notifyIdleIfNoWork(appCtx)
        }
    }

    private fun recordPlaylistItemFailure(
        appCtx: Context,
        record: PlaylistRuntimeRecord,
        idx: Int,
        errMsg: String,
    ) {
        val items = record.snapshot.getJSONArray("items")
        val item = items.getJSONObject(idx)
        synchronized(stateLock) {
            item.put("status", "Failed")
            item.put("error_message", errMsg)
            recomputePlaylistCounters(record.snapshot)
        }
        saveManifestAtomic(File(record.stagingDir), record.snapshot)
        persistPlaylistPointer(appCtx, record)
        emitPlaylistEvent(
            makePlaylistItemEvent(
                snap = record.snapshot,
                kind = "PlaylistItemFailed",
                itemIndex = idx,
                itemStatus = "Failed",
                selectedQuality = item.optString("selected_quality").takeIf { it.isNotBlank() },
                audioLanguage = item.opt("audio_language"),
                message = errMsg,
            ),
        )
    }

    private fun revertInterruptedPlaylistItem(
        record: PlaylistRuntimeRecord,
        idx: Int,
        stopMode: String,
    ) {
        val items = record.snapshot.getJSONArray("items")
        synchronized(stateLock) {
            val item = items.optJSONObject(idx)
            if (item != null) {
                item.put("status", if (stopMode == "pause") "Pending" else "Canceled")
            }
            if (stopMode == "cancel") {
                for (j in (idx + 1) until items.length()) {
                    val rest = items.getJSONObject(j)
                    if (rest.optString("status") == "Pending") {
                        rest.put("status", "Canceled")
                    }
                }
            }
            recomputePlaylistCounters(record.snapshot)
        }
    }

    private fun reconcilePlaylistSnapshot(context: Context, snap: JSONObject) {
        snap.put("is_running", false)
        val items = snap.optJSONArray("items") ?: JSONArray()
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            when (item.optString("status")) {
                "Analyzing", "Ready", "Downloading", "Merging" -> {
                    item.put("status", "Pending")
                }
                "Completed" -> {
                    val path = item.optString("output_path").takeIf { it.isNotBlank() }
                    if (!AndroidMediaStoreExporter.existsExported(context, path)) {
                        item.put("status", "Pending")
                        item.put("output_path", JSONObject.NULL)
                        item.put("downloaded_bytes", 0)
                    }
                }
            }
        }
        recomputePlaylistCounters(snap)
    }

    private fun recomputePlaylistCounters(snap: JSONObject) {
        val items = snap.optJSONArray("items") ?: JSONArray()
        var completed = 0
        var failed = 0
        var skipped = 0
        for (i in 0 until items.length()) {
            when (items.getJSONObject(i).optString("status")) {
                "Completed" -> completed++
                "Failed" -> failed++
                "Skipped" -> skipped++
            }
        }
        snap.put("completed_count", completed)
        snap.put("failed_count", failed)
        snap.put("skipped_count", skipped)
        snap.put("total_count", items.length())
    }

    private fun computeStemsForItems(items: JSONArray): List<String> {
        val total = items.length().coerceAtLeast(1)
        val width = total.toString().length.coerceAtLeast(3)
        val used = HashSet<String>(items.length())
        val stems = ArrayList<String>(items.length())
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val orderIdx = item.optInt("order_index", i)
            val title = AndroidMediaStoreExporter.sanitizeSegment(item.optString("title"), 90)
            val baseStem = "${(orderIdx + 1).toString().padStart(width, '0')} - $title"
            if (used.add(baseStem.lowercase())) {
                stems.add(baseStem)
            } else {
                var suffix = 2
                while (true) {
                    val candidate = "$baseStem ($suffix)"
                    if (used.add(candidate.lowercase())) {
                        stems.add(candidate)
                        break
                    }
                    suffix++
                }
            }
        }
        return stems
    }

    private fun playlistFolderName(title: String, playlistId: String): String {
        val safeTitle = AndroidMediaStoreExporter.sanitizeSegment(title, 72)
        val safeId = AndroidMediaStoreExporter.sanitizeSegment(playlistId, 48)
        return "$safeTitle [$safeId]"
    }

    private fun saveManifestAtomic(stagingDir: File, snap: JSONObject) {
        runCatching {
            stagingDir.mkdirs()
            val temp = File(stagingDir, "$MANIFEST_FILENAME.tmp")
            val target = File(stagingDir, MANIFEST_FILENAME)
            temp.writeText(snap.toString(2))
            if (target.exists()) target.delete()
            if (!temp.renameTo(target)) {
                target.writeText(snap.toString(2))
                temp.delete()
            }
        }
    }

    private fun makePlaylistBatchEvent(
        snap: JSONObject,
        kind: String,
        message: String?,
    ): String {
        return JSONObject().apply {
            put("session_id", snap.getString("session_id"))
            put("kind", kind)
            put("item_index", JSONObject.NULL)
            put("item_status", JSONObject.NULL)
            put("selected_quality", JSONObject.NULL)
            put("audio_language", JSONObject.NULL)
            put("item_downloaded_bytes", 0)
            put("item_total_bytes", JSONObject.NULL)
            put("item_is_total_estimated", false)
            put("speed_bytes_per_sec", JSONObject.NULL)
            put("eta_seconds", JSONObject.NULL)
            put("output_path", JSONObject.NULL)
            put("completed_count", snap.getInt("completed_count"))
            put("failed_count", snap.getInt("failed_count"))
            put("skipped_count", snap.getInt("skipped_count"))
            put("total_count", snap.getInt("total_count"))
            put("playlist_output_dir", snap.getString("output_directory"))
            put("message", message ?: JSONObject.NULL)
        }.toString()
    }

    private fun makePlaylistItemEvent(
        snap: JSONObject,
        kind: String,
        itemIndex: Int,
        itemStatus: String,
        selectedQuality: String?,
        audioLanguage: Any?,
        message: String?,
    ): String {
        return JSONObject().apply {
            put("session_id", snap.getString("session_id"))
            put("kind", kind)
            put("item_index", itemIndex)
            put("item_status", itemStatus)
            put("selected_quality", selectedQuality ?: JSONObject.NULL)
            put("audio_language", audioLanguage ?: JSONObject.NULL)
            put("item_downloaded_bytes", 0)
            put("item_total_bytes", JSONObject.NULL)
            put("item_is_total_estimated", false)
            put("speed_bytes_per_sec", JSONObject.NULL)
            put("eta_seconds", JSONObject.NULL)
            put("output_path", JSONObject.NULL)
            put("completed_count", snap.getInt("completed_count"))
            put("failed_count", snap.getInt("failed_count"))
            put("skipped_count", snap.getInt("skipped_count"))
            put("total_count", snap.getInt("total_count"))
            put("playlist_output_dir", snap.getString("output_directory"))
            put("message", message ?: JSONObject.NULL)
        }.toString()
    }

    // --- Background lifecycle, continuous checkpointing, & OS process-death recovery ---

    fun attachJobService(service: HyperDownloadJobService, params: JobParameters) {
        synchronized(stateLock) {
            boundJobService = service to params
        }
    }

    fun detachJobService(params: JobParameters) {
        synchronized(stateLock) {
            if (boundJobService?.second?.jobId == params.jobId) {
                boundJobService = null
            }
        }
    }

    fun attachForegroundService(service: HyperDownloadForegroundService) {
        synchronized(stateLock) {
            boundForegroundService = service
        }
    }

    fun detachForegroundService(service: HyperDownloadForegroundService) {
        synchronized(stateLock) {
            if (boundForegroundService === service) {
                boundForegroundService = null
            }
        }
    }

    fun currentNotificationSummary(context: Context): NotificationSummary {
        return latestNotificationSummary
    }

    /**
     * Called when `JobService.onStartJob` or `ForegroundService.onStartCommand` starts.
     * If work is already running in-memory, keeps the service bound; otherwise checks durable
     * checkpoints to recover interrupted transfers after process termination.
     */
    fun ensureBackgroundExecution(context: Context): Boolean {
        val appCtx = context.applicationContext
        val alreadyRunning = synchronized(stateLock) {
            activeSingleJob?.isRunning == true || activePlaylistSession?.isRunning == true
        }
        if (alreadyRunning) return true

        // Check durable single-job checkpoint first.
        val singleFile = File(checkpointsDir(appCtx), SINGLE_CHECKPOINT_FILE)
        if (singleFile.isFile) {
            val cp = runCatching { JSONObject(singleFile.readText()) }.getOrNull()
            if (cp != null && cp.optString("status") == "running") {
                val record = SingleJobRecord(
                    jobId = cp.getString("job_id"),
                    requestJson = cp.getString("request_json"),
                    title = cp.optString("title", "Resuming Download"),
                    stagingDir = cp.getString("staging_dir"),
                    isRunning = true,
                    downloadedBytes = cp.optLong("downloaded_bytes", 0L),
                    totalBytes = if (cp.isNull("total_bytes")) null else cp.optLong("total_bytes"),
                    lastPhase = cp.optString("phase", "Downloading"),
                )
                synchronized(stateLock) {
                    activeSingleJob = record
                }
                Log.i(TAG, "Recovered interrupted single download ${record.jobId} from checkpoint")
                launchSingleWorker(appCtx, record)
                return true
            }
        }

        // Check durable playlist checkpoint.
        val ptrFile = File(checkpointsDir(appCtx), PLAYLIST_POINTER_FILE)
        if (ptrFile.isFile) {
            val ptr = runCatching { JSONObject(ptrFile.readText()) }.getOrNull()
            if (ptr != null && ptr.optBoolean("is_running", false)) {
                val stagingDir = File(ptr.getString("staging_dir"))
                val manifestFile = File(stagingDir, MANIFEST_FILENAME)
                val snap = manifestFile.takeIf { it.isFile }?.let {
                    runCatching { JSONObject(it.readText()) }.getOrNull()
                }
                if (snap != null) {
                    reconcilePlaylistSnapshot(appCtx, snap)
                    snap.put("is_running", true)
                    snap.put("is_paused", false)
                    val record = PlaylistRuntimeRecord(
                        snapshot = snap,
                        stagingDir = stagingDir.absolutePath,
                        stems = computeStemsForItems(snap.getJSONArray("items")),
                        isRunning = true,
                    )
                    synchronized(stateLock) {
                        activePlaylistSession = record
                    }
                    Log.i(
                        TAG,
                        "Recovered interrupted playlist ${snap.getString("session_id")} from checkpoint",
                    )
                    launchPlaylistWorker(appCtx, record)
                    return true
                }
            }
        }

        return false
    }

    fun onBackgroundJobStopped(context: Context): Boolean {
        val appCtx = context.applicationContext
        val (singleJobId, playlistSid, playlistJobId) = synchronized(stateLock) {
            Triple(
                activeSingleJob?.takeIf { it.isRunning }?.jobId,
                activePlaylistSession?.takeIf { it.isRunning }?.snapshot?.optString("session_id"),
                activePlaylistSession?.takeIf { it.isRunning }?.activeItemJobId,
            )
        }
        if (singleJobId != null) {
            runCatching { workerModule(appCtx).callAttr("cancel_job", singleJobId) }
            return true
        }
        if (playlistSid != null) {
            synchronized(stateLock) {
                activePlaylistSession?.stopMode = "pause"
            }
            if (playlistJobId != null) {
                runCatching { workerModule(appCtx).callAttr("cancel_job", playlistJobId) }
            }
            return true
        }
        return false
    }

    fun cancelAllFromNotification(context: Context) {
        val appCtx = context.applicationContext
        val (singleId, plId) = synchronized(stateLock) {
            Pair(
                activeSingleJob?.takeIf { it.isRunning }?.jobId,
                activePlaylistSession?.takeIf { it.isRunning }?.snapshot?.optString("session_id"),
            )
        }
        if (singleId != null) {
            runCatching { cancelDownload(appCtx, singleId) }
        }
        if (plId != null) {
            runCatching { cancelPlaylistDownload(appCtx, plId) }
        }
    }

    private fun maybeCheckpointSingle(appCtx: Context, record: SingleJobRecord, phase: String) {
        val now = System.currentTimeMillis()
        if (phase == record.lastPhase && now - lastCheckpointMs < 1000L) {
            return
        }
        lastCheckpointMs = now
        persistSingleCheckpoint(appCtx, record, "running")
    }

    private fun persistSingleCheckpoint(appCtx: Context, record: SingleJobRecord, status: String) {
        runCatching {
            val file = File(checkpointsDir(appCtx), SINGLE_CHECKPOINT_FILE)
            val tmp = File(checkpointsDir(appCtx), "$SINGLE_CHECKPOINT_FILE.tmp")
            val json = JSONObject().apply {
                put("job_id", record.jobId)
                put("request_json", record.requestJson)
                put("title", record.title)
                put("staging_dir", record.stagingDir)
                put("status", status)
                put("phase", record.lastPhase)
                put("downloaded_bytes", record.downloadedBytes)
                put("total_bytes", record.totalBytes ?: JSONObject.NULL)
                put("updated_at_ms", System.currentTimeMillis())
            }
            tmp.writeText(json.toString())
            if (file.exists()) file.delete()
            tmp.renameTo(file)
        }
    }

    private fun clearSingleCheckpoint(appCtx: Context) {
        runCatching {
            File(checkpointsDir(appCtx), SINGLE_CHECKPOINT_FILE).delete()
        }
    }

    private fun persistPlaylistPointer(appCtx: Context, record: PlaylistRuntimeRecord) {
        runCatching {
            val file = File(checkpointsDir(appCtx), PLAYLIST_POINTER_FILE)
            val tmp = File(checkpointsDir(appCtx), "$PLAYLIST_POINTER_FILE.tmp")
            val json = JSONObject().apply {
                put("session_id", record.snapshot.getString("session_id"))
                put("playlist_id", record.snapshot.getString("playlist_id"))
                put("staging_dir", record.stagingDir)
                put("is_running", record.isRunning)
                put("is_paused", record.snapshot.optBoolean("is_paused", false))
                put("updated_at_ms", System.currentTimeMillis())
            }
            tmp.writeText(json.toString())
            if (file.exists()) file.delete()
            tmp.renameTo(file)
        }
    }

    private fun maybeUpdateSingleNotification(
        appCtx: Context,
        title: String,
        phase: String,
        downloaded: Long,
        total: Long?,
        speedBps: Double?,
    ) {
        val now = System.currentTimeMillis()
        if (phase == "Downloading" && now - lastNotificationMs < 500L) {
            return
        }
        lastNotificationMs = now
        val percent = if (phase == "Merging") {
            null
        } else if (total != null && total > 0L) {
            ((downloaded.toDouble() / total.toDouble()) * 100.0).toInt().coerceIn(0, 100)
        } else {
            null
        }
        val subtitle = when (phase) {
            "Analyzing" -> "Analyzing streams..."
            "Merging" -> "Merging video & audio with FFmpeg..."
            else -> {
                val pctStr = if (percent != null) "$percent% · " else ""
                val speedStr = if (speedBps != null && speedBps > 0) {
                    formatSpeedHuman(speedBps)
                } else {
                    formatBytesHuman(downloaded)
                }
                "$pctStr$speedStr"
            }
        }
        latestNotificationSummary = NotificationSummary(
            title = title,
            subtitle = subtitle,
            percent = percent,
            indeterminate = percent == null,
        )
        TransferNotificationManager.updateProgressNotification(
            context = appCtx,
            title = title,
            contentText = subtitle,
            progressPercent = percent,
            indeterminate = percent == null,
        )
    }

    private fun updatePlaylistNotification(
        appCtx: Context,
        snap: JSONObject,
        subtitle: String,
    ) {
        val now = System.currentTimeMillis()
        if (now - lastNotificationMs < 500L && !subtitle.startsWith("Analyzing")) {
            return
        }
        lastNotificationMs = now
        val completed = snap.optInt("completed_count", 0)
        val skipped = snap.optInt("skipped_count", 0)
        val total = snap.optInt("total_count", 0).coerceAtLeast(1)
        val pct = (((completed + skipped).toDouble() / total.toDouble()) * 100.0).toInt()
            .coerceIn(0, 100)
        val title = "${snap.optString("playlist_title")} ($completed/$total)"
        latestNotificationSummary = NotificationSummary(
            title = title,
            subtitle = subtitle,
            percent = pct,
            indeterminate = false,
        )
        TransferNotificationManager.updateProgressNotification(
            context = appCtx,
            title = title,
            contentText = subtitle,
            progressPercent = pct,
            indeterminate = false,
        )
    }

    private fun notifyIdleIfNoWork(appCtx: Context) {
        val (hasWork, jobPair, fgService) = synchronized(stateLock) {
            val work = activeSingleJob?.isRunning == true || activePlaylistSession?.isRunning == true
            Triple(work, boundJobService, boundForegroundService)
        }
        if (hasWork) return

        if (jobPair != null) {
            synchronized(stateLock) {
                boundJobService = null
            }
            mainHandler.post {
                runCatching { jobPair.first.jobFinished(jobPair.second, false) }
            }
        }
        if (fgService != null) {
            synchronized(stateLock) {
                boundForegroundService = null
            }
            mainHandler.post {
                runCatching {
                    fgService.stopForeground(android.app.Service.STOP_FOREGROUND_REMOVE)
                    fgService.stopSelf()
                }
            }
        }
        HyperDownloadTransferScheduler.cancelScheduledJobs(appCtx)
    }

    private fun emitDownloadEvent(json: String) {
        val emitter = downloadEventEmitter ?: return
        mainHandler.post { emitter(json) }
    }

    private fun emitPlaylistEvent(json: String) {
        val emitter = playlistEventEmitter ?: return
        mainHandler.post { emitter(json) }
    }

    private fun emitSizeEstimateEvent(json: String) {
        val emitter = sizeEstimateEventEmitter ?: return
        mainHandler.post { emitter(json) }
    }

    private fun formatBytesHuman(bytes: Long): String {
        val kb = 1024.0
        val mb = kb * 1024.0
        val gb = mb * 1024.0
        val v = bytes.toDouble()
        return when {
            v < kb -> "$bytes B"
            v < mb -> String.format("%.1f KB", v / kb)
            v < gb -> String.format("%.2f MB", v / mb)
            else -> String.format("%.2f GB", v / gb)
        }
    }

    private fun formatSpeedHuman(bps: Double): String {
        val kb = 1024.0
        val mb = kb * 1024.0
        return when {
            bps < kb -> "${bps.toInt()} B/s"
            bps < mb -> String.format("%.1f KB/s", bps / kb)
            else -> String.format("%.2f MB/s", bps / mb)
        }
    }
}

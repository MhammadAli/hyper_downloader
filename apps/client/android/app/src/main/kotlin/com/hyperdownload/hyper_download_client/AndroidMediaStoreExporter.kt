package com.hyperdownload.hyper_download_client

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream

data class ExportedMediaResult(
    val displayPath: String,
    val contentUri: String,
    val verifiedBytes: Long,
)

/**
 * Exports verified staged files directly into top-level user-visible folders:
 * `HyperDownload/Videos` and `HyperDownload/Audio` at external storage root,
 * indexes them with `MediaScannerConnection`, and handles opening or viewing folders.
 */
object AndroidMediaStoreExporter {
    private const val TAG = "AndroidMediaStore"
    private const val ROOT_FOLDER = "HyperDownload"
    private const val URI_INDEX_FILENAME = "exported_uris.json"
    private val AUDIO_EXTENSIONS = setOf("m4a", "mp3", "opus", "ogg", "flac", "wav")
    private val KNOWN_MEDIA_EXTENSIONS = setOf(
        "mp4", "m4v", "webm", "mkv", "m4a", "mp3", "opus", "ogg", "flac", "wav", "part", "ytdl",
    )
    private val indexLock = Any()

    fun isAudioFileName(fileName: String): Boolean {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return ext in AUDIO_EXTENSIONS
    }

    fun hasTopLevelStorageAccess(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun publicRelativeDir(isAudio: Boolean, subfolder: String? = null): String {
        val mediaSub = if (isAudio) "Audio" else "Videos"
        val cleanSub = subfolder
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { sanitizeSegment(it, 90) }
        return if (cleanSub != null) {
            "$ROOT_FOLDER/$mediaSub/$cleanSub"
        } else {
            "$ROOT_FOLDER/$mediaSub"
        }
    }

    fun publicDisplayDir(isAudio: Boolean, subfolder: String? = null): String {
        return "/storage/emulated/0/${publicRelativeDir(isAudio, subfolder)}"
    }

    fun exportFile(
        context: Context,
        stagedFile: File,
        desiredFileName: String,
        playlistSubfolder: String? = null,
    ): ExportedMediaResult {
        require(stagedFile.isFile && stagedFile.length() > 0L) {
            "Staged file missing or empty: ${stagedFile.absolutePath}"
        }
        val expectedBytes = stagedFile.length()
        val safeName = sanitizeSegment(desiredFileName, 140).ifBlank { stagedFile.name }
        val safeSubfolder = playlistSubfolder
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { sanitizeSegment(it, 90) }
        val mimeType = resolveMimeType(safeName)
        val isAudio = isAudioFileName(safeName)
        val relativeDir = publicRelativeDir(isAudio, safeSubfolder)

        if (!hasTopLevelStorageAccess(context)) {
            throw IllegalStateException(
                "Storage access is required to save files into the HyperDownload folder. Please allow 'All files access' (or Storage permission) and try again.",
            )
        }

        @Suppress("DEPRECATION")
        val extRoot = Environment.getExternalStorageDirectory()
        val targetDir = File(extRoot, relativeDir)
        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw IllegalStateException("Failed to create folder: ${targetDir.absolutePath}")
        }

        val destFile = resolveUniqueFile(targetDir, safeName)
        FileInputStream(stagedFile).use { input ->
            destFile.outputStream().use { output ->
                input.copyTo(output, bufferSize = 64 * 1024)
                output.flush()
            }
        }
        if (destFile.length() != expectedBytes) {
            destFile.delete()
            throw IllegalStateException("Public folder copy size mismatch")
        }
        stagedFile.delete()
        MediaScannerConnection.scanFile(
            context.applicationContext,
            arrayOf(destFile.absolutePath),
            arrayOf(mimeType),
            null,
        )
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            destFile,
        )
        recordMapping(context, destFile.absolutePath, uri.toString())
        if (safeSubfolder != null) {
            recordMapping(context, targetDir.absolutePath, uri.toString())
        }
        return ExportedMediaResult(
            displayPath = destFile.absolutePath,
            contentUri = uri.toString(),
            verifiedBytes = destFile.length(),
        )
    }

        fun existsExported(context: Context, pathOrUri: String?): Boolean {
            if (pathOrUri.isNullOrBlank()) return false
            val direct = File(pathOrUri)
            if (direct.isFile && direct.length() > 0L) {
                return true
            }
            val uri = resolveContentUri(context, pathOrUri) ?: return false
            return runCatching {
                context.contentResolver.query(
                    uri,
                    arrayOf(MediaStore.MediaColumns.SIZE),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                        idx >= 0 && cursor.getLong(idx) > 0L
                    } else {
                        false
                    }
                } ?: false
            }.getOrDefault(false)
        }

        fun openFile(context: Context, pathOrUri: String): Boolean {
            val uri = resolveContentUri(context, pathOrUri) ?: return false
            val mime = resolveMimeType(pathOrUri)
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return runCatching {
                context.startActivity(viewIntent)
                true
            }.getOrElse {
                val genericIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "*/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                runCatching {
                    context.startActivity(genericIntent)
                    true
                }.getOrDefault(false)
            }
        }

    fun revealInFolder(context: Context, pathOrUri: String): Boolean {
        val relativeFolder = resolveRelativeFolderPath(context, pathOrUri)
        val docId = "primary:$relativeFolder"
        val dirUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            docId,
        )

        val dirIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dirUri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val dirOpened = runCatching {
            context.startActivity(dirIntent)
            true
        }.onFailure { err ->
            Log.w(TAG, "revealInFolder MIME_TYPE_DIR failed for $dirUri: ${err.message}")
        }.getOrDefault(false)
        if (dirOpened) {
            return true
        }

        val resourceFolderIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dirUri, "resource/folder")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val resourceOpened = runCatching {
            context.startActivity(resourceFolderIntent)
            true
        }.onFailure { err ->
            Log.w(TAG, "revealInFolder resource/folder failed for $dirUri: ${err.message}")
        }.getOrDefault(false)
        if (resourceOpened) {
            return true
        }

        val rootUri = DocumentsContract.buildRootUri(
            "com.android.externalstorage.documents",
            "primary",
        )
        val rootIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(rootUri, DocumentsContract.Root.MIME_TYPE_ITEM)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val rootOpened = runCatching {
            context.startActivity(rootIntent)
            true
        }.onFailure { err ->
            Log.w(TAG, "revealInFolder root fallback failed: ${err.message}")
        }.getOrDefault(false)
        if (rootOpened) {
            return true
        }

        val filesAppIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_APP_FILES)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(filesAppIntent)
            true
        }.onFailure { err ->
            Log.w(TAG, "revealInFolder APP_FILES fallback failed: ${err.message}")
        }.getOrDefault(false)
    }

    private fun resolveRelativeFolderPath(context: Context, pathOrUri: String): String {
        val defaultFolder = publicRelativeDir(isAudioFileName(pathOrUri))
        val mappedUri = if (pathOrUri.startsWith("content://")) {
            Uri.parse(pathOrUri)
        } else {
            lookupMapping(context, pathOrUri)?.let { Uri.parse(it) }
        }

        if (mappedUri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val queriedFolder = queryMediaStoreRelativeFolder(context, mappedUri)
            if (!queriedFolder.isNullOrBlank()) {
                return queriedFolder
            }
        }

        val normalized = pathOrUri.replace('\\', '/').trim()
        @Suppress("DEPRECATION")
        val extRoot = Environment.getExternalStorageDirectory().absolutePath
            .replace('\\', '/')
            .trimEnd('/')
        var relative = when {
            normalized.startsWith("/storage/emulated/0/") ->
                normalized.removePrefix("/storage/emulated/0/")

            extRoot.isNotEmpty() && normalized.startsWith("$extRoot/") ->
                normalized.removePrefix("$extRoot/")

            normalized.startsWith("$ROOT_FOLDER/") ||
                normalized.startsWith("${Environment.DIRECTORY_MOVIES}/") ||
                normalized.startsWith("${Environment.DIRECTORY_MUSIC}/") ||
                normalized.startsWith("${Environment.DIRECTORY_DOWNLOADS}/") -> normalized

            else -> ""
        }.trim('/')

            if (relative.isEmpty()) {
                return defaultFolder
            }

            val localFile = File(pathOrUri)
            if (!localFile.isDirectory) {
                val lastSegment = relative.substringAfterLast('/', relative)
                val ext = lastSegment.substringAfterLast('.', "").lowercase()
                val looksLikeMediaFile = localFile.isFile || ext in KNOWN_MEDIA_EXTENSIONS
                if (looksLikeMediaFile && relative.contains('/')) {
                    relative = relative.substringBeforeLast('/')
                }
            }

            return relative.ifBlank { defaultFolder }
        }

        private fun queryMediaStoreRelativeFolder(context: Context, uri: Uri): String? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                return null
            }
            return runCatching {
                context.contentResolver.query(
                    uri,
                    arrayOf(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        MediaStore.MediaColumns.DATA,
                    ),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val relIdx = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                    val relPath = if (relIdx >= 0) cursor.getString(relIdx) else null
                    if (!relPath.isNullOrBlank()) {
                        return@use relPath.replace('\\', '/').trim('/').takeIf { it.isNotEmpty() }
                    }
                    val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    val dataPath = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                    if (!dataPath.isNullOrBlank()) {
                        val parent = File(dataPath).parent?.replace('\\', '/') ?: return@use null
                        val extRoot = Environment.getExternalStorageDirectory().absolutePath
                            .replace('\\', '/')
                            .trimEnd('/')
                        return@use when {
                            parent.startsWith("/storage/emulated/0/") ->
                                parent.removePrefix("/storage/emulated/0/").trim('/')

                            extRoot.isNotEmpty() && parent.startsWith("$extRoot/") ->
                                parent.removePrefix("$extRoot/").trim('/')

                            else -> null
                        }?.takeIf { it.isNotEmpty() }
                    }
                    null
                }
            }.getOrNull()
        }

        fun shareFile(context: Context, pathOrUri: String): Boolean {
            val uri = resolveContentUri(context, pathOrUri) ?: return false
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = resolveMimeType(pathOrUri)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(shareIntent, "Share download").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return runCatching {
                context.startActivity(chooser)
                true
            }.getOrDefault(false)
        }

        private fun resolveContentUri(context: Context, pathOrUri: String): Uri? {
            if (pathOrUri.startsWith("content://")) {
                return Uri.parse(pathOrUri)
            }
            val mapped = lookupMapping(context, pathOrUri)
            if (mapped != null) {
                return Uri.parse(mapped)
            }
            val file = File(pathOrUri)
            if (file.isFile) {
                return runCatching {
                    FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        file,
                    )
                }.getOrNull()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val projection = arrayOf(MediaStore.MediaColumns._ID)
                val selection = "${MediaStore.MediaColumns.DATA} = ?"
                val args = arrayOf(pathOrUri)
                            val collections = listOf(
                                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            )
                            for (collectionUri in collections) {
                                runCatching {
                                    context.contentResolver.query(
                                        collectionUri,
                                        projection,
                                        selection,
                                        args,
                                        null,
                                    )?.use { cursor ->
                                        if (cursor.moveToFirst()) {
                                            val id = cursor.getLong(0)
                                            return ContentUris.withAppendedId(
                                                collectionUri,
                                                id,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        return null
                    }

                    private fun recordMapping(context: Context, path: String, uri: String) {
                        synchronized(indexLock) {
                            val file = File(context.applicationContext.filesDir, URI_INDEX_FILENAME)
                            val map = runCatching {
                                if (file.isFile) JSONObject(file.readText()) else JSONObject()
                            }.getOrElse { JSONObject() }
                            map.put(path, uri)
                            file.writeText(map.toString())
                        }
                    }

                    private fun lookupMapping(context: Context, path: String): String? {
                        synchronized(indexLock) {
                            val file = File(context.applicationContext.filesDir, URI_INDEX_FILENAME)
                            if (!file.isFile) return null
                            val map = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return null
                            return map.optString(path).takeIf { it.isNotBlank() }
                        }
                    }

                    fun sanitizeSegment(raw: String, maxChars: Int): String {
                        val sb = StringBuilder(raw.length)
                        var prevSpace = true
                        for (ch in raw) {
                            val forbidden =
                                ch in charArrayOf('<', '>', ':', '"', '/', '\\', '|', '?', '*') || ch.isISOControl()
                            val mapped = if (forbidden || ch.isWhitespace()) ' ' else ch
                            if (mapped == ' ') {
                                if (!prevSpace) {
                                    sb.append(' ')
                                    prevSpace = true
                                }
                            } else {
                                sb.append(mapped)
                                prevSpace = false
                            }
                        }
                        val cleaned = sb.toString().trim { it == ' ' || it == '.' }
                        val truncated = cleaned.take(maxChars).trim { it == ' ' || it == '.' }
                        return truncated.ifEmpty { "Untitled" }
                    }

                    private fun resolveMimeType(fileName: String): String {
                        val ext = fileName.substringAfterLast('.', "").lowercase()
                        return when (ext) {
                            "mp4", "m4v" -> "video/mp4"
                            "webm" -> "video/webm"
                            "mkv" -> "video/x-matroska"
                            "m4a" -> "audio/mp4"
                            "mp3" -> "audio/mpeg"
                            "opus" -> "audio/opus"
                            "ogg" -> "audio/ogg"
                            "flac" -> "audio/flac"
                            "wav" -> "audio/wav"
                            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                                ?: "application/octet-stream"
                        }
                    }

                    private fun resolveUniqueFile(dir: File, fileName: String): File {
                        var candidate = File(dir, fileName)
                        if (!candidate.exists()) return candidate
                        val dot = fileName.lastIndexOf('.')
                        val stem = if (dot > 0) fileName.substring(0, dot) else fileName
                        val ext = if (dot > 0) fileName.substring(dot) else ""
                        var index = 2
                        while (candidate.exists()) {
                            candidate = File(dir, "$stem ($index)$ext")
                            index++
                        }
                        return candidate
                    }
                }

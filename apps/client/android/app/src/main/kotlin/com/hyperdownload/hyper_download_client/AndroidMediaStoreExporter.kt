package com.hyperdownload.hyper_download_client

import android.app.DownloadManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
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
 * Exports verified staged files into Android's shared Downloads collection via
 * `MediaStore.Downloads` (API 29+) and handles opening or viewing downloads.
 */
object AndroidMediaStoreExporter {
    private const val ROOT_FOLDER = "HyperDownload"
    private const val URI_INDEX_FILENAME = "exported_uris.json"
    private val KNOWN_MEDIA_EXTENSIONS = setOf(
        "mp4", "m4v", "webm", "mkv", "m4a", "mp3", "opus", "ogg", "flac", "wav", "part", "ytdl",
    )
    private val indexLock = Any()

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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val relativeDir = if (safeSubfolder != null) {
                "${Environment.DIRECTORY_DOWNLOADS}/$ROOT_FOLDER/$safeSubfolder"
            } else {
                "${Environment.DIRECTORY_DOWNLOADS}/$ROOT_FOLDER"
            }
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val itemUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore.Downloads.insert returned null")

            var finalized = false
            try {
                resolver.openOutputStream(itemUri, "w")?.use { outStream ->
                    FileInputStream(stagedFile).use { inStream ->
                        inStream.copyTo(outStream, bufferSize = 64 * 1024)
                    }
                    outStream.flush()
                } ?: throw IllegalStateException("Failed to open OutputStream for $itemUri")

                val publishValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                resolver.update(itemUri, publishValues, null, null)
                finalized = true

                var verifiedSize = -1L
                var resolvedPath: String? = null
                resolver.query(
                    itemUri,
                    arrayOf(
                        MediaStore.MediaColumns.SIZE,
                        MediaStore.MediaColumns.DATA,
                        MediaStore.MediaColumns.DISPLAY_NAME,
                    ),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                        val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                        val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                        if (sizeIdx >= 0) verifiedSize = cursor.getLong(sizeIdx)
                        if (dataIdx >= 0) resolvedPath = cursor.getString(dataIdx)
                        if (resolvedPath.isNullOrBlank() && nameIdx >= 0) {
                            val actualName = cursor.getString(nameIdx) ?: safeName
                            resolvedPath = "/storage/emulated/0/$relativeDir/$actualName"
                        }
                    }
                }

                if (verifiedSize <= 0L) {
                    resolver.openAssetFileDescriptor(itemUri, "r")?.use { afd ->
                        verifiedSize = afd.length
                    }
                }
                if (verifiedSize != expectedBytes) {
                    throw IllegalStateException(
                        "Exported size verification mismatch (expected=$expectedBytes, actual=$verifiedSize)",
                    )
                }

                val displayPath =
                    resolvedPath?.takeIf { it.isNotBlank() }
                        ?: "/storage/emulated/0/$relativeDir/$safeName"
                recordMapping(context, displayPath, itemUri.toString())
                if (safeSubfolder != null) {
                    val folderDisplay = "/storage/emulated/0/$relativeDir"
                    recordMapping(context, folderDisplay, itemUri.toString())
                }
                stagedFile.delete()
                return ExportedMediaResult(
                    displayPath = displayPath,
                    contentUri = itemUri.toString(),
                    verifiedBytes = verifiedSize,
                )
            } catch (t: Throwable) {
                if (!finalized) {
                    runCatching { resolver.delete(itemUri, null, null) }
                }
                throw t
            }
        }

        // API 26-28 fallback into app-specific Downloads or public Downloads if permitted.
        val baseDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: File(context.filesDir, "downloads")
        val targetDir = if (safeSubfolder != null) {
            File(File(baseDir, ROOT_FOLDER), safeSubfolder)
        } else {
            File(baseDir, ROOT_FOLDER)
        }
        targetDir.mkdirs()
        val destFile = resolveUniqueFile(targetDir, safeName)
        FileInputStream(stagedFile).use { input ->
            destFile.outputStream().use { output ->
                input.copyTo(output, bufferSize = 64 * 1024)
                output.flush()
            }
        }
        if (destFile.length() != expectedBytes) {
            destFile.delete()
            throw IllegalStateException("Legacy Downloads copy size mismatch")
        }
        stagedFile.delete()
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            destFile,
        )
        recordMapping(context, destFile.absolutePath, uri.toString())
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
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (runCatching { context.startActivity(dirIntent); true }.getOrDefault(false)) {
            return true
        }

        val resourceFolderIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dirUri, "resource/folder")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (runCatching { context.startActivity(resourceFolderIntent); true }.getOrDefault(false)) {
            return true
        }

        val downloadsIntent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (runCatching { context.startActivity(downloadsIntent); true }.getOrDefault(false)) {
            return true
        }
        return shareFile(context, pathOrUri)
    }

    private fun resolveRelativeFolderPath(context: Context, pathOrUri: String): String {
        val defaultFolder = "${Environment.DIRECTORY_DOWNLOADS}/$ROOT_FOLDER"
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
        val extRoot = Environment.getExternalStorageDirectory().absolutePath
            .replace('\\', '/')
            .trimEnd('/')
        var relative = when {
            normalized.startsWith("/storage/emulated/0/") ->
                normalized.removePrefix("/storage/emulated/0/")
            extRoot.isNotEmpty() && normalized.startsWith("$extRoot/") ->
                normalized.removePrefix("$extRoot/")
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
            runCatching {
                context.contentResolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    projection,
                    selection,
                    args,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val id = cursor.getLong(0)
                        return ContentUris.withAppendedId(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            id,
                        )
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

package com.hyperdownload.hyper_download_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

object TransferNotificationManager {
    const val CHANNEL_PROGRESS_ID = "hyperdl_transfers"
    const val CHANNEL_ALERTS_ID = "hyperdl_transfer_alerts"
    const val NOTIFICATION_PROGRESS_ID = 4101
    const val NOTIFICATION_ALERT_ID = 4102
    const val ACTION_CANCEL_TRANSFER = "com.hyperdownload.action.CANCEL_TRANSFER"

    fun ensureChannels(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_PROGRESS_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_PROGRESS_ID,
                    "Active Downloads",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shows progress for ongoing media and playlist downloads"
                    setShowBadge(false)
                },
            )
        }
        if (nm.getNotificationChannel(CHANNEL_ALERTS_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ALERTS_ID,
                    "Download Completion",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Notifies when downloads finish or require attention"
                },
            )
        }
    }

    fun buildProgressNotification(
        context: Context,
        title: String,
        contentText: String,
        progressPercent: Int?,
        indeterminate: Boolean,
        cancellable: Boolean = true,
    ): Notification {
        ensureChannels(context)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPi = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = Notification.Builder(context, CHANNEL_PROGRESS_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(contentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPi)
            .setProgress(100, (progressPercent ?: 0).coerceIn(0, 100), indeterminate)

        if (cancellable) {
            val cancelIntent = Intent(context, TransferNotificationActionReceiver::class.java).apply {
                action = ACTION_CANCEL_TRANSFER
            }
            val cancelPi = PendingIntent.getBroadcast(
                context,
                1001,
                cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                Notification.Action.Builder(
                    null,
                    "Cancel",
                    cancelPi,
                ).build(),
            )
        }

        return builder.build()
    }

    fun updateProgressNotification(
        context: Context,
        title: String,
        contentText: String,
        progressPercent: Int?,
        indeterminate: Boolean,
    ) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = buildProgressNotification(
            context = context,
            title = title,
            contentText = contentText,
            progressPercent = progressPercent,
            indeterminate = indeterminate,
        )
        runCatching { nm.notify(NOTIFICATION_PROGRESS_ID, notification) }
    }

    fun clearProgressNotification(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { nm.cancel(NOTIFICATION_PROGRESS_ID) }
    }

    fun showTerminalNotification(
        context: Context,
        title: String,
        contentText: String,
        isError: Boolean,
    ) {
        ensureChannels(context)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPi = PendingIntent.getActivity(
            context,
            1,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ALERTS_ID)
            .setSmallIcon(
                if (isError) {
                    android.R.drawable.stat_notify_error
                } else {
                    android.R.drawable.stat_sys_download_done
                },
            )
            .setContentTitle(title)
            .setContentText(contentText)
            .setAutoCancel(true)
            .setContentIntent(contentPi)
            .build()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching { nm.notify(NOTIFICATION_ALERT_ID, notification) }
    }
}

object HyperDownloadTransferScheduler {
    const val UIDT_JOB_ID = 41001

    fun scheduleTransferExecution(
        context: Context,
        estimatedDownloadBytes: Long? = null,
    ) {
        val appCtx = context.applicationContext
        TransferNotificationManager.ensureChannels(appCtx)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val scheduler = appCtx.getSystemService(JobScheduler::class.java)
            val component = ComponentName(appCtx, HyperDownloadJobService::class.java)
            val builder = JobInfo.Builder(UIDT_JOB_ID, component)
                .setUserInitiated(true)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            if (estimatedDownloadBytes != null && estimatedDownloadBytes > 0L) {
                builder.setEstimatedNetworkBytes(estimatedDownloadBytes, 0L)
            }
            val result = runCatching { scheduler.schedule(builder.build()) }.getOrNull()
            if (result == JobScheduler.RESULT_SUCCESS) {
                return
            }
        }

        // API 26-33 fallback (and safety net if UIDT cannot be scheduled).
        val intent = Intent(appCtx, HyperDownloadForegroundService::class.java)
        runCatching { appCtx.startForegroundService(intent) }
    }

    fun cancelScheduledJobs(context: Context) {
        val appCtx = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val scheduler = appCtx.getSystemService(JobScheduler::class.java)
            runCatching { scheduler.cancel(UIDT_JOB_ID) }
        }
    }
}

/**
 * Android 14+ (API 34+) User-Initiated Data Transfer JobService driving both
 * foreground-initiated transfers and process-death recovery.
 */
class HyperDownloadJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val appCtx = applicationContext
        val summary = AndroidDownloadEngine.currentNotificationSummary(appCtx)
        val notification = TransferNotificationManager.buildProgressNotification(
            context = appCtx,
            title = summary.title,
            contentText = summary.subtitle,
            progressPercent = summary.percent,
            indeterminate = summary.indeterminate,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            setNotification(
                params,
                TransferNotificationManager.NOTIFICATION_PROGRESS_ID,
                notification,
                JOB_END_NOTIFICATION_POLICY_REMOVE,
            )
        }

        AndroidDownloadEngine.attachJobService(this, params)
        val activeOrRecovered = AndroidDownloadEngine.ensureBackgroundExecution(appCtx)
        if (!activeOrRecovered) {
            AndroidDownloadEngine.detachJobService(params)
            jobFinished(params, false)
            return false
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        // System preempted job (e.g., network loss). Pause cleanly; durable checkpoints
        // are already persisted continuously and do not rely solely on onStopJob().
        val shouldReschedule = AndroidDownloadEngine.onBackgroundJobStopped(applicationContext)
        AndroidDownloadEngine.detachJobService(params)
        return shouldReschedule
    }
}

/**
 * Android 8.0-13 (API 26-33) Foreground Service fallback for background dataSync transfers.
 */
class HyperDownloadForegroundService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val appCtx = applicationContext
        val summary = AndroidDownloadEngine.currentNotificationSummary(appCtx)
        val notification = TransferNotificationManager.buildProgressNotification(
            context = appCtx,
            title = summary.title,
            contentText = summary.subtitle,
            progressPercent = summary.percent,
            indeterminate = summary.indeterminate,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                TransferNotificationManager.NOTIFICATION_PROGRESS_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(TransferNotificationManager.NOTIFICATION_PROGRESS_ID, notification)
        }

        AndroidDownloadEngine.attachForegroundService(this)
        val activeOrRecovered = AndroidDownloadEngine.ensureBackgroundExecution(appCtx)
        if (!activeOrRecovered) {
            AndroidDownloadEngine.detachForegroundService(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        AndroidDownloadEngine.detachForegroundService(this)
        super.onDestroy()
    }
}

class TransferNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == TransferNotificationManager.ACTION_CANCEL_TRANSFER) {
            AndroidDownloadEngine.cancelAllFromNotification(context.applicationContext)
        }
    }
}

package com.jev.probe.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * A minimal foreground service whose only job is to keep the app process at
 * foreground importance so MIUI/HyperOS "Greezer" does not freeze the
 * accessibility service (which otherwise dies within seconds — see P1 report).
 * Not a full fix on its own: the user must also grant autostart / no battery
 * restriction, but this holds the process while the app is set up and running.
 */
class KeepAliveService : Service() {

    override fun onCreate() {
        super.onCreate()
        val channelId = "jev_keepalive"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(channelId, "小助手运行中", NotificationManager.IMPORTANCE_MIN)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        // 「唤出助手」兜底：悬浮胶囊被拖丢/遮住时，通知上一按就展开卡片。
        // 走 ChatCaptureService 的 onStartCommand（SUMMON action），不开新界面。
        val summon = android.app.PendingIntent.getService(
            this, 1,
            Intent(this, ChatCaptureService::class.java).setAction(ACTION_SUMMON),
            android.app.PendingIntent.FLAG_IMMUTABLE)
        val notif: Notification = Notification.Builder(this, channelId)
            .setContentTitle("小助手运行中")
            .setContentText("在聊天旁读消息、给回复建议")
            .setSmallIcon(android.R.drawable.ic_menu_edit)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "唤出助手", summon).build())
            .build()
        startForeground(1, notif)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        /** 通知「唤出助手」的动作；[ChatCaptureService.onStartCommand] 消费。 */
        const val ACTION_SUMMON = "com.jev.probe.action.SUMMON_OVERLAY"

        fun start(ctx: Context) {
            val i = Intent(ctx, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
            else ctx.startService(i)
        }
    }
}

package org.omilocal.next

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

private const val channelId = "omi_next_task_reminders"
private val taskId = Regex("[A-Za-z0-9_-]{1,128}")

internal class NextReminders(private val context: Context) {
    private data class Reminder(val id: String, val at: Long, val title: String, val body: String, val exact: Boolean) {
        fun json() = JSONObject().put("id", id).put("at", at).put("title", title).put("body", body).put("exact", exact)
    }

    private val preferences = context.getSharedPreferences("next.task.reminders", Context.MODE_PRIVATE)
    private val alarms = requireNotNull(context.getSystemService(AlarmManager::class.java))
    private val notifications = requireNotNull(context.getSystemService(NotificationManager::class.java))

    private fun load(): List<Reminder> {
        val stored = JSONArray(preferences.getString("alarms", "[]"))
        return List(stored.length()) { position ->
            val item = stored.getJSONObject(position)
            Reminder(item.getString("id"), item.getLong("at"), item.getString("title"), item.getString("body"),
                item.getBoolean("exact"))
        }
    }

    private fun save(reminders: List<Reminder>) {
        check(preferences.edit().putString("alarms", JSONArray(reminders.map { it.json() }).toString())
            .putBoolean("precise", precise()).commit())
    }

    private fun ensureChannel() {
        notifications.createNotificationChannel(NotificationChannel(channelId, "Task reminders", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun allowed() = notifications.areNotificationsEnabled() &&
        notifications.getNotificationChannel(channelId)?.importance != NotificationManager.IMPORTANCE_NONE

    private fun precise() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()

    fun status(): Map<String, Boolean> {
        ensureChannel()
        return mapOf("allowed" to allowed(), "precise" to precise())
    }

    private fun alarm(reminder: Reminder, flags: Int): PendingIntent? {
        val intent = Intent(context, NextReminderReceiver::class.java)
            .setAction(NextReminderReceiver.FIRE)
            .setData(Uri.Builder().scheme("ominext").authority("reminder")
                .appendPath(reminder.id).appendPath(reminder.at.toString()).build())
        return PendingIntent.getBroadcast(context, 0, intent, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun cancel(reminder: Reminder) {
        alarm(reminder, PendingIntent.FLAG_NO_CREATE)?.let {
            alarms.cancel(it)
            it.cancel()
        }
    }

    private fun schedule(reminder: Reminder) {
        if (reminder.at <= System.currentTimeMillis()) return
        val operation = alarm(reminder, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        if (reminder.exact && precise()) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, operation)
                return
            } catch (_: SecurityException) {
                // Permission can change between canScheduleExactAlarms and scheduling.
            }
        }
        try {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, operation)
        } catch (error: RuntimeException) {
            operation.cancel()
            throw error
        }
    }

    fun replace(arguments: Any?): Map<String, Boolean> {
        val items = arguments as List<*>
        require(items.size <= 96)
        val requested = items.map { entry ->
            val item = entry as Map<*, *>
            Reminder(item["id"] as String, (item["at"] as Number).toLong(), item["title"] as String,
                item["body"] as String, item["exact"] as Boolean).also {
                require(taskId.matches(it.id) && it.title.length in 1..128 && it.body.length in 1..400)
            }
        }
        require(requested.map { it.id }.toSet().size == requested.size)
        val current = load()
        val state = status()
        val now = System.currentTimeMillis()
        val previous = current.associateBy { it.id }
        val active = if (state.getValue("allowed")) {
            requested.filter { it.at > now || previous[it.id]?.at == it.at }
        } else emptyList()
        val modeChanged = preferences.getBoolean("precise", state.getValue("precise")) != state.getValue("precise")
        save(active)
        val next = active.associateBy { it.id }
        for (item in current) {
            if (next[item.id]?.at != item.at) {
                cancel(item)
                notifications.cancel(item.id, 0)
            }
        }
        for (item in active) {
            if (item.at > now && (previous[item.id] != item || modeChanged ||
                    alarm(item, PendingIntent.FLAG_NO_CREATE) == null)) schedule(item)
        }
        return status()
    }

    fun clear() {
        replace(emptyList<Any>())
        for (shown in notifications.activeNotifications) {
            if (shown.notification.channelId == channelId) notifications.cancel(shown.tag, shown.id)
        }
    }

    fun restore() {
        ensureChannel()
        if (!allowed()) return
        val pending = load().filter { it.at > System.currentTimeMillis() }
        save(pending)
        pending.forEach(::schedule)
    }

    fun deliver(id: String, at: Long) {
        val all = load()
        val reminder = all.firstOrNull { it.id == id && it.at == at } ?: return
        save(all.filterNot { it.id == id })
        ensureChannel()
        if (!allowed()) return
        val launch = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(reminder.title)
            .setContentText(reminder.body)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(launch)
            .setAutoCancel(true)
            .build()
        notifications.notify(id, 0, notification)
    }
}

class NextReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reminders = NextReminders(context)
        when (intent.action) {
            FIRE -> intent.data?.pathSegments?.let { fields ->
                val at = fields.getOrNull(1)?.toLongOrNull()
                if (fields.size == 2 && at != null) reminders.deliver(fields[0], at)
            }
            Intent.ACTION_BOOT_COMPLETED, AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED ->
                reminders.restore()
        }
    }

    companion object {
        const val FIRE = "org.omilocal.next.TASK_REMINDER"
    }
}

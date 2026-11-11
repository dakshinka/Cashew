package com.budget.tracker_app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    private val SMS_CHANNEL = "com.budget.tracker_app/sms_inbox"
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var smsChannel: MethodChannel? = null
    private var smsContentObserver: ContentObserver? = null
    private var smsBroadcastReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
        smsChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkSmsPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "requestSmsPermission" -> {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
                        registerSmsObservers()
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS), 505)
                    }
                }
                "startListeningForSms" -> {
                    registerSmsObservers()
                    result.success(true)
                }
                "querySmsInbox" -> {
                    val days = call.argument<Int>("days") ?: 60
                    val limit = call.argument<Int>("limit") ?: 500
                    val startTimeMillis = (call.argument<Number>("startTimeMillis"))?.toLong()
                    val endTimeMillis = (call.argument<Number>("endTimeMillis"))?.toLong()
                    try {
                        val messages = readSmsInbox(days, limit, startTimeMillis, endTimeMillis)
                        result.success(messages)
                    } catch (e: Exception) {
                        result.error("SMS_QUERY_ERROR", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
            registerSmsObservers()
        }
    }

    private fun registerSmsObservers() {
        try {
            // 1. ContentObserver on content://sms: triggers immediately when any SMS app inserts a new message
            if (smsContentObserver == null) {
                smsContentObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
                    override fun onChange(selfChange: Boolean, uri: Uri?) {
                        super.onChange(selfChange, uri)
                        smsChannel?.invokeMethod("onSmsInboxChanged", null)
                    }
                }
                contentResolver.registerContentObserver(
                    Uri.parse("content://sms"),
                    true,
                    smsContentObserver!!
                )
            }

            // 2. BroadcastReceiver for SMS_RECEIVED: catches incoming SMS broadcasts directly from the carrier
            if (smsBroadcastReceiver == null) {
                smsBroadcastReceiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        if (intent?.action == Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
                            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
                            for (sms in messages) {
                                val body = sms.displayMessageBody ?: sms.messageBody ?: ""
                                val sender = sms.displayOriginatingAddress ?: sms.originatingAddress ?: "SMS"
                                val timestamp = sms.timestampMillis
                                if (body.isNotBlank()) {
                                    val data = HashMap<String, Any>()
                                    data["body"] = body
                                    data["address"] = sender
                                    data["date"] = timestamp
                                    smsChannel?.invokeMethod("onRawSmsReceived", data)
                                }
                            }
                        }
                    }
                }
                val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
                registerReceiver(smsBroadcastReceiver, filter)
            }
        } catch (e: Exception) {
            // Permission might not be granted yet or device restriction
        }
    }

    override fun onDestroy() {
        smsContentObserver?.let {
            try { contentResolver.unregisterContentObserver(it) } catch (_: Exception) {}
        }
        smsBroadcastReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 505) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                registerSmsObservers()
            }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun readSmsInbox(days: Int, limit: Int, startTimeMillis: Long?, endTimeMillis: Long?): List<Map<String, Any>> {
        val resultList = mutableListOf<Map<String, Any>>()
        val uri = Uri.parse("content://sms/inbox")

        val selection: String?
        val selectionArgs: Array<String>?

        if (startTimeMillis != null && endTimeMillis != null) {
            selection = "date >= ? AND date <= ?"
            selectionArgs = arrayOf(startTimeMillis.toString(), endTimeMillis.toString())
        } else if (startTimeMillis != null) {
            selection = "date >= ?"
            selectionArgs = arrayOf(startTimeMillis.toString())
        } else {
            val cutoffTime = if (days > 0) System.currentTimeMillis() - (days.toLong() * 24 * 60 * 60 * 1000) else 0L
            selection = if (cutoffTime > 0) "date >= ?" else null
            selectionArgs = if (cutoffTime > 0) arrayOf(cutoffTime.toString()) else null
        }

        val projection = arrayOf("_id", "address", "body", "date")
        val sortOrder = "date DESC"

        val cursor = contentResolver.query(uri, projection, selection, selectionArgs, sortOrder)
        cursor?.use {
            val addressIdx = it.getColumnIndex("address")
            val bodyIdx = it.getColumnIndex("body")
            val dateIdx = it.getColumnIndex("date")

            var count = 0
            while (it.moveToNext() && count < limit) {
                val address = if (addressIdx != -1) it.getString(addressIdx) ?: "" else ""
                val body = if (bodyIdx != -1) it.getString(bodyIdx) ?: "" else ""
                val dateMillis = if (dateIdx != -1) it.getLong(dateIdx) else 0L

                val lowerBody = body.lowercase()

                // Exclude pure spam, marketing, and OTPs upfront
                val isExcluded = lowerBody.contains("otp") ||
                                 lowerBody.contains("verification code") ||
                                 lowerBody.contains("pre-approved") ||
                                 lowerBody.contains("pre approved") ||
                                 lowerBody.contains("apply now") ||
                                 lowerBody.contains("claim now") ||
                                 lowerBody.contains("flat rs") ||
                                 lowerBody.contains("discount of up to") ||
                                 lowerBody.contains("cashback of up to")

                if (isExcluded) continue

                val isFinancial = lowerBody.contains("debited") ||
                                  lowerBody.contains("credited") ||
                                  lowerBody.contains("deposited") ||
                                  lowerBody.contains("depoisited") ||
                                  lowerBody.contains("salary") ||
                                  lowerBody.contains("spent") ||
                                  lowerBody.contains("paid") ||
                                  lowerBody.contains("sent") ||
                                  lowerBody.contains("withdrawn") ||
                                  lowerBody.contains("purchase") ||
                                  lowerBody.contains("charged") ||
                                  lowerBody.contains("inr") ||
                                  lowerBody.contains("rs.") ||
                                  lowerBody.contains("rs ") ||
                                  lowerBody.contains("rs.") ||
                                  lowerBody.contains("₹") ||
                                  lowerBody.contains("upi") ||
                                  lowerBody.contains("transferred") ||
                                  lowerBody.contains("refund") ||
                                  lowerBody.contains("cashback") ||
                                  lowerBody.contains("a/c") ||
                                  lowerBody.contains("acct") ||
                                  lowerBody.contains("e-mandate") ||
                                  lowerBody.contains("mandate") ||
                                  lowerBody.contains("card") ||
                                  lowerBody.contains("bank") ||
                                  lowerBody.contains("hdfc") ||
                                  lowerBody.contains("sbi") ||
                                  lowerBody.contains("icici") ||
                                  lowerBody.contains("axis") ||
                                  lowerBody.contains("rbl") ||
                                  lowerBody.contains("kotak")

                if (isFinancial && body.isNotBlank()) {
                    val map = HashMap<String, Any>()
                    map["address"] = address
                    map["body"] = body
                    map["date"] = dateMillis
                    resultList.add(map)
                    count++
                }
            }
        }
        return resultList
    }
}

package `in`.sixthsense.sixthsense_app

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val volumeSosPattern = VolumeSosPattern()

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 &&
            volumeSosPattern.onVolumeKey(event.keyCode, event.eventTime)
        ) {
            LocalSosNotifier.show(this)
        }
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestSos" -> result.success(LocalSosNotifier.show(this))
                    "requestCovertSos" -> result.success(
                        OfflineSafetyDispatcher.sendSosIfConfigured(this, "Covert SOS"),
                    )
                    "requestDuress" -> result.success(
                        OfflineSafetyDispatcher.sendSosIfConfigured(this, "Duress alert"),
                    )
                    "startJourney", "checkIn" -> {
                        val deadlineMillis = call.argument<Number>("deadlineMillis")?.toLong()
                        val smsNumbers = call.argument<List<String>>("smsNumbers").orEmpty()
                        val smsFallbackEnabled = call.argument<Boolean>("smsFallbackEnabled") ?: false
                        if (deadlineMillis == null) {
                            result.error("invalid_journey", "Journey details are missing.", null)
                        } else {
                            startOrUpdateJourney(
                                deadlineMillis,
                                smsNumbers,
                                smsFallbackEnabled,
                                isCheckIn = call.method == "checkIn",
                                result = result,
                            )
                        }
                    }
                    "endJourney" -> {
                        JourneyAlarm.cancel(this)
                        startService(
                            Intent(this, JourneyTimerService::class.java)
                                .setAction(JourneyTimerService.ACTION_STOP),
                        )
                        result.success(null)
                    }
                    "requestExactAlarmAccess" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            !getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
                        ) {
                            startActivity(
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                    .setData(Uri.parse("package:$packageName")),
                            )
                        }
                        result.success(null)
                    }
                    "requestBatteryExemption" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                        .setData(Uri.parse("package:$packageName")),
                                )
                            }
                        }
                        result.success(null)
                    }
                    "journeyReliabilityStatus" -> result.success(reliabilityStatus())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IDENTITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getDevicePublicKey" -> result.success(DeviceIdentityVault.publicKey())
                        "signDeviceChallenge" -> {
                            val deviceId = call.argument<String>("deviceId")
                            val nonce = call.argument<String>("nonce")
                            if (deviceId.isNullOrBlank() || nonce.isNullOrBlank()) {
                                result.error("invalid_challenge", "Device challenge is missing.", null)
                            } else {
                                result.success(DeviceIdentityVault.sign(deviceId, nonce))
                            }
                        }
                        "saveSession" -> {
                            val deviceId = call.argument<String>("deviceId")
                            val accountId = call.argument<String>("accountId")
                            val token = call.argument<String>("accessToken")
                            if (deviceId.isNullOrBlank() || accountId.isNullOrBlank() || token.isNullOrBlank()) {
                                result.error("invalid_session", "Session details are missing.", null)
                            } else {
                                DeviceIdentityVault.saveSession(this, deviceId, accountId, token)
                                result.success(null)
                            }
                        }
                        "getDeviceId" -> result.success(DeviceIdentityVault.sessionValue(this, "device_id"))
                        "getAccessToken" -> result.success(DeviceIdentityVault.sessionValue(this, "access_token"))
                        "clearSession" -> {
                            DeviceIdentityVault.clearSession(this)
                            result.success(null)
                        }
                        "shareInvite" -> {
                            val url = call.argument<String>("url")
                            val name = call.argument<String>("contactName").orEmpty()
                            if (url.isNullOrBlank()) {
                                result.error("invalid_invite", "Invite link is missing.", null)
                            } else {
                                val share = Intent(Intent.ACTION_SEND)
                                    .setType("text/plain")
                                    .putExtra(Intent.EXTRA_TEXT, "Join me on SixthSense so I can share safety alerts with you: $url")
                                startActivity(Intent.createChooser(share, "Invite $name to SixthSense"))
                                result.success(null)
                            }
                        }
                        "openUrl" -> {
                            val url = call.argument<String>("url")
                            if (url.isNullOrBlank() || !url.startsWith("https://")) {
                                result.error("invalid_url", "Only HTTPS links can be opened.", null)
                            } else {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                result.success(null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("device_identity_error", "Could not use this device's secure identity.", error.javaClass.simpleName)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRIVACY_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "setScreenshotProtection") {
                    result.notImplemented()
                } else {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
            }
    }

    private fun startOrUpdateJourney(
        deadlineMillis: Long,
        smsNumbers: List<String>,
        smsFallbackEnabled: Boolean,
        isCheckIn: Boolean,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
            result.error(
                "notification_permission_required",
                "Allow notifications, then start the journey again.",
                null,
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            !getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()
        ) {
            result.error(
                "notifications_disabled",
                "Enable notifications in system settings before starting a journey timer.",
                null,
            )
            return
        }

        if (deadlineMillis <= System.currentTimeMillis()) {
            result.error("invalid_deadline", "The next check-in must be in the future.", null)
            return
        }

        if (smsFallbackEnabled) {
            val missingPermissions = mutableListOf<String>()
            if (checkSelfPermission(Manifest.permission.SEND_SMS) !=
                PackageManager.PERMISSION_GRANTED
            ) missingPermissions.add(Manifest.permission.SEND_SMS)
            val hasFineLocation = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            val hasCoarseLocation = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            if (!hasFineLocation && !hasCoarseLocation) {
                missingPermissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
                missingPermissions.add(Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (missingPermissions.isNotEmpty()) {
                requestPermissions(missingPermissions.toTypedArray(), REQUEST_SMS_LOCATION)
                result.error(
                    "sms_permissions_required",
                    "Allow SMS and location, then start the journey again to enable offline alerts.",
                    null,
                )
                return
            }
        }

        if (!JourneyAlarm.schedule(this, deadlineMillis)) {
            result.error(
                "exact_alarm_permission_required",
                "Allow SixthSense to set alarms and reminders, then start the journey again.",
                null,
            )
            return
        }

        JourneyNotifications.createChannels(this)
        val serviceIntent = Intent(this, JourneyTimerService::class.java)
            .setAction(JourneyTimerService.ACTION_START)
            .putExtra(JourneyTimerService.EXTRA_DEADLINE, deadlineMillis)
            .putStringArrayListExtra(
                JourneyTimerService.EXTRA_SMS_NUMBERS,
                ArrayList(smsNumbers),
            )
            .putExtra(JourneyTimerService.EXTRA_SMS_FALLBACK_ENABLED, smsFallbackEnabled)
            .putExtra(JourneyTimerService.EXTRA_IS_CHECK_IN, isCheckIn)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
        result.success(null)
    }

    private fun reliabilityStatus(): Map<String, Boolean> {
        val exactAlarmsAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
        val batteryExemptionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        val notificationsAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        return mapOf(
            "exactAlarmsAllowed" to exactAlarmsAllowed,
            "batteryExemptionGranted" to batteryExemptionGranted,
            "notificationsAllowed" to notificationsAllowed,
        )
    }

    companion object {
        private const val CHANNEL = "in.sixthsense/journey_runtime"
        private const val IDENTITY_CHANNEL = "in.sixthsense/device_identity"
        private const val PRIVACY_CHANNEL = "in.sixthsense/privacy"
        private const val REQUEST_NOTIFICATIONS = 4105
        private const val REQUEST_SMS_LOCATION = 4106
    }
}

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
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sosChannel: MethodChannel? = null
    private var pendingMicResult: MethodChannel.Result? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val debuggable = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        intent.getStringExtra("debug_voice_test_dir")?.takeIf { debuggable }?.let { dir ->
            Thread { SosGuard.recognizeFiles(applicationContext, java.io.File(filesDir, dir)) }.start()
        }
        if (intent.getBooleanExtra(SosGuard.EXTRA_SHOW_COUNTDOWN, false)) {
            SosEvents.emit("showCountdown", SosGuard.current?.snapshot().orEmpty())
        }
    }

    override fun onDestroy() {
        SosEvents.sink = null
        SosGuard.practiceGuard?.stop()
        SosGuard.practiceGuard = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_MICROPHONE) {
            pendingMicResult?.success(SosGuard.micAllowed(this))
            pendingMicResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EvidenceStore.clearExports(this)
        val sos = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SOS_CHANNEL)
        sosChannel = sos
        SosEvents.sink = { name, args -> sos.invokeMethod(name, args) }
        sos.setMethodCallHandler { call, result -> handleSos(call.method, call, result) }
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
                        pendingSosSettings = SosSettings(
                            apiBaseUrl = call.argument<String>("apiBaseUrl"),
                            journeyId = call.argument<String>("journeyId"),
                            listenForWords = call.argument<Boolean>("listenForWords"),
                        )
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
                        "saveValue" -> {
                            val name = call.argument<String>("name")
                            if (name.isNullOrBlank()) {
                                result.error("invalid_value", "Value name is missing.", null)
                            } else {
                                DeviceIdentityVault.saveValue(this, name, call.argument<String>("value"))
                                result.success(null)
                            }
                        }
                        "readValue" -> result.success(
                            call.argument<String>("name")?.let { DeviceIdentityVault.readValue(this, it) },
                        )
                        "clearSession" -> {
                            DeviceIdentityVault.clearSession(this)
                            result.success(null)
                        }
                        "signOut" -> {
                            // Logout: forget the session and this phone's saved values, and
                            // retire the device key so the next sign-in binds a fresh one.
                            DeviceIdentityVault.signOut(this)
                            result.success(null)
                        }
                        "moveToBack" -> {
                            // Back on the home screen: keep the app (and a running journey) alive.
                            moveTaskToBack(true)
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
                            if (url == "tel:112") {
                                // Opens the dialer with 112 filled in; the user presses call.
                                startActivity(Intent(Intent.ACTION_DIAL, Uri.parse(url)))
                                result.success(null)
                            } else if (url.isNullOrBlank() || !url.startsWith("https://")) {
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
            .apply {
                pendingSosSettings?.let { settings ->
                    settings.apiBaseUrl?.let { putExtra(JourneyTimerService.EXTRA_API_BASE, it) }
                    settings.journeyId?.let { putExtra(JourneyTimerService.EXTRA_JOURNEY_ID, it) }
                    settings.listenForWords?.let { putExtra(JourneyTimerService.EXTRA_LISTEN_FOR_WORDS, it) }
                }
                pendingSosSettings = null
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
        result.success(null)
    }

    private data class SosSettings(val apiBaseUrl: String?, val journeyId: String?, val listenForWords: Boolean?)

    private var pendingSosSettings: SosSettings? = null

    /** Sudden SOS, recordings, live audio playback and the voice models (P1-W2). */
    private fun handleSos(method: String, call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val guard = SosGuard.current
        when (method) {
            "guardState" -> result.success(guard?.snapshot() ?: mapOf("state" to "off"))
            "cancelCountdown" -> result.success(guard?.cancelCountdown() ?: false)
            "fireNow" -> {
                guard?.fireNow(covert = call.argument<Boolean>("covert") ?: false)
                result.success(guard != null)
            }
            "alertOver" -> {
                guard?.alertOver()
                result.success(null)
            }
            "startEscortRecording" -> {
                val session = call.argument<String>("session")
                val until = call.argument<Number>("untilMillis")?.toLong()
                if (guard == null || !guard.hasMic || session == null || until == null) {
                    result.success(false)
                } else {
                    guard.startRecording("escort", session, until)
                    result.success(true)
                }
            }
            "stopEscortRecording" -> {
                guard?.stopRecording("escort")
                EvidenceStore.delete(this, "escort", null)
                result.success(null)
            }
            "takeClips" -> {
                val kind = call.argument<String>("kind") ?: "sos"
                result.success(
                    EvidenceStore.take(this, kind).map {
                        mapOf("session" to it.session, "kind" to it.kind, "sequence" to it.sequence, "bytes" to it.bytes)
                    },
                )
            }
            "recordings" -> result.success(EvidenceStore.recordings(this))
            "exportRecording" -> {
                val file = call.argument<String>("session")?.let { EvidenceStore.export(this, it) }
                if (file == null) {
                    result.success(false)
                } else {
                    val uri = FileProvider.getUriForFile(this, "$packageName.evidence", file)
                    val share = Intent(Intent.ACTION_SEND)
                        .setType("audio/aac")
                        .putExtra(Intent.EXTRA_STREAM, uri)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(Intent.createChooser(share, "Save or share the SOS recording"))
                    result.success(true)
                }
            }
            "deleteRecording" -> {
                EvidenceStore.delete(this, "sos", call.argument<String>("session"))
                EvidenceStore.clearExports(this)
                result.success(null)
            }
            "playClip" -> {
                call.argument<String>("path")?.let(ClipPlayer::enqueue)
                result.success(null)
            }
            "stopPlayback" -> {
                ClipPlayer.stop()
                result.success(null)
            }
            "voiceModels" -> result.success(
                mapOf("installed" to VoiceModels.installed(this), "downloading" to VoiceModels.downloading),
            )
            "downloadVoiceModels" -> {
                Thread {
                    var last = -1
                    val ok = VoiceModels.download(applicationContext) { percent ->
                        if (percent != last) {
                            last = percent
                            SosEvents.emit("modelProgress", mapOf("percent" to percent))
                        }
                    }
                    SosEvents.emit("modelDone", mapOf("ok" to ok))
                }.start()
                result.success(null)
            }
            "micPermission" -> result.success(SosGuard.micAllowed(this))
            "requestMicPermission" -> {
                if (SosGuard.micAllowed(this)) {
                    result.success(true)
                } else {
                    pendingMicResult?.success(false)
                    pendingMicResult = result
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
                }
            }
            "startPractice" -> {
                SosGuard.practiceGuard?.stop()
                SosGuard.practiceGuard = if (guard != null) {
                    null // the journey's guard already owns the mic; practice is off during a journey
                } else {
                    SosGuard(applicationContext, practice = true, listenForWords = true).also { it.start() }
                }
                result.success(SosGuard.practiceGuard != null)
            }
            "stopPractice" -> {
                SosGuard.practiceGuard?.stop()
                SosGuard.practiceGuard = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
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
        private const val SOS_CHANNEL = "in.sixthsense/sudden_sos"
        private const val REQUEST_MICROPHONE = 4107
        private const val REQUEST_NOTIFICATIONS = 4105
        private const val REQUEST_SMS_LOCATION = 4106
    }
}

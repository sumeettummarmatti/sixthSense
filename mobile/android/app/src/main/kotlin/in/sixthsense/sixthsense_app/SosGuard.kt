package `in`.sixthsense.sixthsense_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer

/** Sends guard events to the Flutter side when it's attached (MainActivity sets [sink]). */
internal object SosEvents {
    @Volatile var sink: ((String, Map<String, Any?>) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())

    fun emit(name: String, args: Map<String, Any?> = emptyMap()) {
        main.post { sink?.invoke(name, args) }
    }
}

/**
 * Sudden SOS while protection is on (a journey is running), screen off, phone in a pocket:
 *
 * - Volume Down ×5 within 3 s (or held down) → silent countdown → SOS.
 * - "help" / "bachao" / "madad" / "bacha lo" heard on the phone → countdown (3–9 s) → SOS.
 *   A distress word during any countdown sends it at once. Silence never stops it: only the
 *   PIN in the app cancels.
 * - The SOS goes from native code (works with the app closed), with SMS when offline, and the
 *   phone starts recording, keeping the 15 s from before the trigger (held only in memory until
 *   then). Clips are encrypted on the phone; the app sends them end to end to whoever is helping.
 *
 * [practice] mode listens and reports what it heard without counting down or sending anything.
 */
internal class SosGuard(
    private val context: Context,
    private val practice: Boolean,
    private val listenForWords: Boolean,
    private val useMic: Boolean = true,
) : SensorEventListener {
    val listenForWordsSetting get() = listenForWords
    val hasMic get() = useMic

    enum class State { ARMED, COUNTDOWN, FIRED }

    private val main = Handler(Looper.getMainLooper())
    private val ring = PcmRing()
    private val motion = MotionMeter()
    private val presses = VolumePressCounter()
    private val levels = ArrayDeque<Pair<Long, Double>>()

    @Volatile var state = State.ARMED
        private set
    @Volatile private var running = false
    private var micThread: Thread? = null
    private var session: MediaSession? = null
    private var countdownSource: TriggerSource? = null
    private var deadlineMillis = 0L
    @Volatile var listening = false
        private set

    // Recording requests (any thread) → acted on by the mic thread.
    @Volatile private var recordKind: String? = null
    @Volatile private var recordSession: String = "local"
    @Volatile private var recordUntilMillis = 0L
    @Volatile private var preRollPending = false
    private var encoder: AacChunkEncoder? = null
    private var encoderKind: String? = null

    private val fire = Runnable { fireNow() }

    fun start() {
        if (running) return
        Log.i(TAG, "guard start practice=$practice words=$listenForWords mic=$useMic")
        running = true
        startVolumeCapture()
        (context.getSystemService(Context.SENSOR_SERVICE) as SensorManager).let { sensors ->
            sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
            }
        }
        if (useMic && micAllowed(context)) {
            micThread = Thread(::micLoop, "sixthsense-guard-mic").apply { start() }
        }
    }

    fun stop() {
        running = false
        main.removeCallbacks(fire)
        cancelNotification()
        session?.release()
        session = null
        (context.getSystemService(Context.SENSOR_SERVICE) as SensorManager).unregisterListener(this)
        micThread?.join(1_500)
        micThread = null
        ring.clear()
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "state" to state.name.lowercase(),
        "source" to countdownSource?.wire,
        "deadlineMillis" to deadlineMillis,
        "listening" to listening,
        "recording" to recordKind,
    )

    // --- triggers ---------------------------------------------------------------------------

    private fun startVolumeCapture() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        session = MediaSession(context, "SixthSenseGuard").apply {
            // Volume presses are delivered through the callback's handler; without a
            // callback Android drops them silently.
            setCallback(object : MediaSession.Callback() {}, main)
            // A "remote" volume makes Android hand us volume presses even with the screen off.
            setPlaybackToRemote(object : VolumeProvider(VOLUME_CONTROL_RELATIVE, 100, 50) {
                override fun onAdjustVolume(direction: Int) {
                    if (direction == 0) return
                    // Keep the buttons working as normal volume keys too.
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, 0)
                    if (direction < 0 && presses.onPress(SystemClock.elapsedRealtime())) {
                        trigger(TriggerSource.BUTTON, "volume")
                    }
                }
            })
            setPlaybackState(
                PlaybackState.Builder().setState(PlaybackState.STATE_PLAYING, 0, 1f).build(),
            )
            isActive = true
        }
    }

    fun trigger(source: TriggerSource, heard: String) = main.post {
        Log.i(TAG, "trigger ${source.wire} running=$running state=$state practice=$practice")
        if (!running) return@post
        if (practice) {
            SosEvents.emit(
                "heard",
                mapOf(
                    "word" to heard,
                    "source" to source.wire,
                    "countdownSeconds" to CountdownPolicy.seconds(source, loudest(), motion.motion()),
                ),
            )
            return@post
        }
        when (state) {
            State.ARMED -> startCountdown(source, heard)
            State.COUNTDOWN -> if (source == TriggerSource.VOICE) fireNow()
            State.FIRED -> Unit
        }
    }

    private fun startCountdown(source: TriggerSource, heard: String) {
        val seconds = CountdownPolicy.seconds(source, loudest(), motion.motion())
        Log.i(TAG, "countdown ${seconds}s from ${source.wire}")
        state = State.COUNTDOWN
        countdownSource = source
        deadlineMillis = System.currentTimeMillis() + seconds * 1_000L
        vibrate(longArrayOf(0, 90, 120, 90, 120, 90))
        showCountdownNotification()
        SosEvents.emit(
            "countdown",
            mapOf("seconds" to seconds, "source" to source.wire, "heard" to heard, "deadlineMillis" to deadlineMillis),
        )
        main.postDelayed(fire, seconds * 1_000L)
    }

    /** Called by the app after the real PIN. The duress PIN never calls this: it fires instead. */
    fun cancelCountdown(): Boolean {
        if (state != State.COUNTDOWN) return false
        main.removeCallbacks(fire)
        state = State.ARMED
        countdownSource = null
        cancelNotification()
        vibrate(longArrayOf(0, 40))
        SosEvents.emit("cancelled")
        return true
    }

    /** [covert]: the duress PIN was used, so no buzz and a silent alarm (screen stays normal). */
    fun fireNow(covert: Boolean = false) {
        if (state == State.FIRED) return
        Log.i(TAG, "firing SOS covert=$covert")
        main.removeCallbacks(fire)
        state = State.FIRED
        val source = countdownSource ?: TriggerSource.BUTTON
        cancelNotification()
        if (!covert) vibrate(longArrayOf(0, 600))
        val prefs = context.getSharedPreferences(JourneyTimerService.PREFERENCES_NAME, Context.MODE_PRIVATE)
        startRecording(
            "sos",
            prefs.getString(SosApi.KEY_JOURNEY_ID, null) ?: "local-${System.currentTimeMillis()}",
            System.currentTimeMillis() + MAX_SOS_RECORDING_MILLIS,
            preRoll = true,
        )
        Thread {
            val serverOk = SosApi.fire(context, covert)
            val smsSent = OfflineSafetyDispatcher.sendSosIfConfigured(context, "SOS (sudden trigger)")
            SosEvents.emit(
                "fired",
                mapOf("source" to source.wire, "serverOk" to serverOk, "smsSent" to smsSent, "covert" to covert),
            )
        }.start()
    }

    /** The alert is over (resolved by a contact): stop the SOS recording, re-arm. */
    fun alertOver() {
        if (state == State.FIRED) state = State.ARMED
        countdownSource = null
        if (recordKind == "sos") recordKind = null
    }

    // --- recording --------------------------------------------------------------------------

    fun startRecording(kind: String, session: String, untilMillis: Long, preRoll: Boolean = false) {
        if (recordKind == "sos" && kind != "sos") return // the SOS recording wins
        recordSession = session
        recordUntilMillis = untilMillis
        preRollPending = preRoll
        recordKind = kind
    }

    fun stopRecording(kind: String) {
        if (recordKind == kind) recordKind = null
    }

    private fun handleRecording(block: ShortArray, count: Int) {
        val wanted = recordKind?.takeIf { System.currentTimeMillis() < recordUntilMillis }
        if (wanted == null && recordKind != null) recordKind = null
        encoder?.let { current ->
            if (wanted == null || wanted != encoderKind) {
                current.finish()
                encoder = null
                encoderKind = null
            }
        }
        if (encoder == null && wanted != null) {
            val session = recordSession
            encoder = try {
                AacChunkEncoder { clip ->
                    EvidenceStore.save(context, wanted, session, clip)
                    SosEvents.emit("clip", mapOf("kind" to wanted))
                }
            } catch (error: Exception) {
                Log.w(TAG, "AAC encoder unavailable", error)
                recordKind = null
                null
            }
            encoderKind = wanted
            if (preRollPending) {
                preRollPending = false
                val before = ring.snapshot() // already includes this block
                var offset = 0
                while (offset < before.size) {
                    val n = minOf(PIECE, before.size - offset)
                    encoder?.feed(before.copyOfRange(offset, offset + n), n)
                    offset += n
                }
                return
            }
        }
        encoder?.feed(block, count)
    }

    // --- microphone + voice -----------------------------------------------------------------

    private fun micLoop() {
        val minBuffer = AudioRecord.getMinBufferSize(
            AacChunkEncoder.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                AacChunkEncoder.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, AacChunkEncoder.SAMPLE_RATE),
            )
        } catch (error: SecurityException) {
            Log.w(TAG, "Microphone not allowed", error)
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return
        }
        val recognizers = if (listenForWords) loadRecognizers() else emptyList()
        listening = recognizers.isNotEmpty()
        SosEvents.emit("listening", mapOf("listening" to listening))
        record.startRecording()
        val block = ShortArray(PIECE)
        var speechUntil = 0L
        var lastLevelLog = 0L
        val cooldownUntil = LongArray(recognizers.size)
        try {
            while (running) {
                val n = record.read(block, 0, block.size)
                if (n <= 0) continue
                ring.write(block, n)
                val now = SystemClock.elapsedRealtime()
                val level = dbfs(block, n)
                synchronized(levels) {
                    levels.addLast(now to level)
                    while (levels.isNotEmpty() && now - levels.first().first > 1_500) levels.removeFirst()
                }
                handleRecording(block, n)
                if (practice && now - lastLevelLog > 5_000) {
                    lastLevelLog = now
                    Log.d(TAG, "practice mic level ${"%.0f".format(loudest())} dBFS")
                }
                if (recognizers.isEmpty()) continue
                if (level > SPEECH_DBFS) speechUntil = now + 1_500
                if (now > speechUntil) continue // silence: save battery
                recognizers.forEachIndexed { index, recognizer ->
                    val final = recognizer.acceptWaveForm(block, n)
                    val json = JSONObject(if (final) recognizer.result else recognizer.partialResult)
                    val text = json.optString(if (final) "text" else "partial")
                    if (practice && final && text.isNotBlank()) {
                        // Shown on this phone's practice screen only; never logged or sent.
                        SosEvents.emit("transcript", mapOf("text" to text))
                    }
                    val word = DistressWords.find(text)
                    if (word != null && now > cooldownUntil[index]) {
                        cooldownUntil[index] = now + 2_000
                        recognizer.reset()
                        trigger(TriggerSource.VOICE, word)
                    }
                }
            }
        } finally {
            record.stop()
            record.release()
            encoder?.finish()
            encoder = null
            recognizers.forEach(Recognizer::close)
            models.forEach(Model::close)
            models.clear()
            listening = false
        }
    }

    private val models = mutableListOf<Model>()

    private fun loadRecognizers(): List<Recognizer> = try {
        LibVosk.setLogLevel(LogLevel.WARNINGS)
        VoiceModels.installed(context).map { language ->
            val model = Model(VoiceModels.dir(context, language).path)
            models += model
            Recognizer(model, AacChunkEncoder.SAMPLE_RATE.toFloat())
        }
    } catch (error: Throwable) {
        Log.w(TAG, "Voice models could not load", error)
        emptyList()
    }

    private fun loudest(): Double = synchronized(levels) { levels.maxOfOrNull { it.second } ?: -96.0 }

    override fun onSensorChanged(event: SensorEvent) {
        motion.add(SystemClock.elapsedRealtime(), event.values[0], event.values[1], event.values[2])
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // --- feedback ---------------------------------------------------------------------------

    private fun vibrate(pattern: LongArray) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
    }

    private fun showCountdownNotification() {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Sudden SOS countdown", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Lets you cancel an SOS started by the volume buttons or your voice."
                    enableVibration(false) // we vibrate ourselves, discreetly
                    setSound(null, null)
                },
            )
        }
        val open = PendingIntent.getActivity(
            context,
            4110,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(EXTRA_SHOW_COUNTDOWN, true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("SixthSense")
            .setContentText("Tap to cancel with your PIN")
            .setWhen(deadlineMillis)
            .setUsesChronometer(true)
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) setChronometerCountDown(true) }
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setCategory(Notification.CATEGORY_ALARM)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(COUNTDOWN_NOTIFICATION_ID, notification)
    }

    private fun cancelNotification() {
        context.getSystemService(NotificationManager::class.java).cancel(COUNTDOWN_NOTIFICATION_ID)
    }

    companion object {
        private const val TAG = "SixthSenseGuard"
        private const val CHANNEL_ID = "sudden_sos"
        private const val COUNTDOWN_NOTIFICATION_ID = 4111
        private const val PIECE = 1_600 // 100 ms
        private const val SPEECH_DBFS = -55.0
        private const val MAX_SOS_RECORDING_MILLIS = 60 * 60 * 1000L
        const val EXTRA_SHOW_COUNTDOWN = "show_sos_countdown"

        /** The guard of the running journey, if any. */
        @Volatile var current: SosGuard? = null

        /** Practice mode, started from the app's Sudden SOS screen. */
        @Volatile var practiceGuard: SosGuard? = null

        /**
         * Debug builds only: run the on-phone recognisers and word matching over 16 kHz mono
         * WAV files (used to test voice SOS on an emulator without a microphone).
         */
        fun recognizeFiles(context: Context, dir: java.io.File) {
            LibVosk.setLogLevel(LogLevel.WARNINGS)
            val models = VoiceModels.installed(context).associateWith { Model(VoiceModels.dir(context, it).path) }
            for (file in dir.listFiles { f -> f.name.endsWith(".wav") }.orEmpty().sortedBy { it.name }) {
                val bytes = file.readBytes()
                val pcm = ShortArray((bytes.size - 44) / 2) { i ->
                    ((bytes[44 + 2 * i].toInt() and 0xFF) or (bytes[45 + 2 * i].toInt() shl 8)).toShort()
                }
                val silence = ShortArray(8_000)
                val padded = silence + pcm + silence
                val heard = mutableListOf<String>()
                val texts = mutableListOf<String>()
                for ((language, model) in models) {
                    val recognizer = Recognizer(model, AacChunkEncoder.SAMPLE_RATE.toFloat())
                    var offset = 0
                    var found: String? = null
                    while (offset < padded.size) {
                        val n = minOf(PIECE, padded.size - offset)
                        val chunk = padded.copyOfRange(offset, offset + n)
                        val final = recognizer.acceptWaveForm(chunk, n)
                        val json = JSONObject(if (final) recognizer.result else recognizer.partialResult)
                        found = found ?: DistressWords.find(json.optString(if (final) "text" else "partial"))
                        offset += n
                    }
                    val text = JSONObject(recognizer.finalResult).optString("text")
                    found = found ?: DistressWords.find(text)
                    texts += "$language=[$text]"
                    found?.let { heard += it }
                    recognizer.close()
                }
                Log.i(TAG, "VOICETEST ${file.name}: ${if (heard.isEmpty()) "-" else "HIT ${heard.joinToString()}"} ${texts.joinToString(" ")}")
            }
            models.values.forEach(Model::close)
            Log.i(TAG, "VOICETEST done")
        }

        fun micAllowed(context: Context) = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }
}

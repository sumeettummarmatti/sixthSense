# Voice SOS: Vosk talks to its native library through JNA, which finds classes and
# methods by reflection. Keep them so release builds can still load the speech models.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

# ML Kit text recognition (ID-photo OCR): only the Latin recognizer is bundled. The plugin
# references the optional Chinese/Devanagari/Japanese/Korean packs, which we do not ship.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit face detection (the "Confirm it's you" scan) and text recognition (ID-photo OCR) create
# their component registrars by reflection. R8 removed those constructors, so every call failed
# with "getClass() on a null object reference" in release builds only. Keep them.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google.android.odml.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_face_detection.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }

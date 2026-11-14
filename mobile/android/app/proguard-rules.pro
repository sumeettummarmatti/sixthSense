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

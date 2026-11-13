# Voice SOS: Vosk talks to its native library through JNA, which finds classes and
# methods by reflection. Keep them so release builds can still load the speech models.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

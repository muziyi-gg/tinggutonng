# Flutter default rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep MethodChannel classes
-keep class com.tingutong.app.** { *; }

# Keep SharedPreferences keys (FlutterSharedPreferences)
-keepclassmembers class * {
    public static *;
}

# Flutter TTS
-keep class com.ryanhecholine.audiosession.** { *; }

# http package
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# WebSocket
-dontwarn okio.**
-dontwarn okhttp.**

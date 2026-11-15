# libwebrtc calls back into Java through JNI by class and method name (also in the artifact's consumer rules).
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Release builds carry no verbose/debug logging. Protocol events use Log.i through Logcat and never contain keys
# or the pairing URI.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}

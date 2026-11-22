# Preserve Chaquopy Kotlin<->Python callback interfaces and methods against R8 optimization/obfuscation.
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

-keep @androidx.annotation.Keep class * {
    *;
}

-keep interface com.hyperdownload.hyper_download_client.PythonStringCallback {
    public void onEvent(java.lang.String);
}

-keep class * implements com.hyperdownload.hyper_download_client.PythonStringCallback {
    public void onEvent(java.lang.String);
}

-keepclassmembers class * implements com.hyperdownload.hyper_download_client.PythonStringCallback {
    public void onEvent(java.lang.String);
}

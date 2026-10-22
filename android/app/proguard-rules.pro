# youtubedl-android parses yt-dlp's JSON with Jackson, which needs the original
# class/field names at runtime; R8 renaming breaks its initialisation.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.compress.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.compress.**
-dontwarn java.beans.**
-dontwarn org.w3c.dom.bootstrap.**

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ouo.ouoplayer"
    // permission_handler_android needs API 37, installed as the "android-37.0" platform.
    compileSdkVersion("android-37.0")
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ouo.ouoplayer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // README screenshots come from a separate demo copy (lib/config/demo.dart).
        val demo = System.getenv("OUO_DEMO") == "true"
        if (demo) applicationIdSuffix = ".demo"
        manifestPlaceholders["appLabel"] = if (demo) "OuOPlayer Demo" else "OuOPlayer"
    }

    // Releases are signed with the same key since v0.1 (this PC's debug key),
    // kept outside the repo so in-app updates keep installing over the old
    // app. OUO_KEYSTORE can point elsewhere; release.ps1 refuses to build
    // without it, so a lost key never quietly becomes a new one.
    val ouoKey = file(System.getenv("OUO_KEYSTORE") ?: "D:/dev/ouoplayer-keys/ouoplayer.keystore")
    signingConfigs {
        create("ouo") {
            storeFile = ouoKey
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (ouoKey.exists()) "ouo" else "debug")
        }
    }

    packaging {
        // youtubedl-android extracts its bundled Python/ffmpeg from the native lib dir.
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    // Knowing when Android Auto is connected (lyrics in the car).
    implementation("androidx.car.app:app:1.4.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

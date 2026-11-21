plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

android {
    namespace = "com.hyperdownload.hyper_download_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hyperdownload.hyper_download_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Initial Android release targets 64-bit ABIs only (32-bit ARM/x86 excluded).
        ndk {
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

chaquopy {
    defaultConfig {
        version = "3.13"

        val overridePy = System.getenv("HYPERDL_BUILD_PYTHON")?.takeIf { it.isNotBlank() }
        val localAppData = System.getenv("LOCALAPPDATA")
        val defaultPy313 = localAppData?.let { file("$it/Programs/Python/Python313/python.exe") }
        if (overridePy != null) {
            buildPython(overridePy)
        } else if (defaultPy313 != null && defaultPy313.exists()) {
            buildPython(defaultPy313.absolutePath)
        }

        pip {
            install("yt-dlp==2026.10.26")
            install("yt-dlp-ejs==0.8.0")
            install("certifi")
        }
        extractPackages("yt_dlp_ejs", "certifi")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

apply(from = "cargokit.gradle")

// Android app module — the generic Android RECEIVER (free: 1 pad ↔ 1 mac, wired via adb + wireless).
// Depends on the pure-Kotlin :protocol module. The receiver pipeline (TCP server, MediaCodec decode →
// SurfaceView, MotionEvent/KeyEvent capture) lands in the next increments; today it carries the
// conformance-locked wire protocol + an app shell so the project builds and runs in Android Studio.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.superconnect.receiver"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.superconnect.receiver"
        minSdk = 24          // Android 7 — broad coverage incl. older Huawei Android tablets
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
}

dependencies {
    implementation(project(":protocol"))
}

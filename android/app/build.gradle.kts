// Android app module — the generic Android RECEIVER (free: 1 pad ↔ 1 mac, wired via adb + wireless).
// Depends on the pure-Kotlin :protocol module. Pure Kotlin, NO native libs → one universal APK runs on
// every ABI (arm/arm64/x86), minSdk 24. Release builds are signed with a STABLE keystore (see below) so
// the APK is properly installable, updatable in place, and distributable to arbitrary Android devices.
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing is driven by a gitignored `android/keystore.properties` (storeFile/storePassword/
// keyAlias/keyPassword). When it's absent (e.g. a fresh clone / CI without the secret), release builds
// fall back to the debug signature so the project still builds — see android/sign-release.md.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val hasReleaseKey = keystorePropsFile.exists()

android {
    namespace = "com.superconnect.receiver"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.superconnect.receiver"
        minSdk = 24          // Android 7 — broad coverage incl. older Huawei Android tablets
        targetSdk = 35
        versionCode = 2
        versionName = "0.2"
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false   // no R8: the receiver leans on reflection-free Kotlin; keep it simple
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
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

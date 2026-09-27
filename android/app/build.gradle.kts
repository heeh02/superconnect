// FOSS-P1 Android Receiver: optional consented input + canonical Rust Auth/Record via :core-wire.
// The local trial is arm64-only and has a package identity separate from old free/Standard/root apps.
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing is driven by a gitignored `android/keystore.properties` (storeFile/storePassword/
// keyAlias/keyPassword). Debug builds do not need it. Release builds fail closed when the file,
// a required field, or the configured keystore is missing — see android/sign-release.md.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.isFile) keystorePropsFile.inputStream().use { load(it) }
}
val requiredReleaseSigningProperties = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
val configuredStorePath = keystoreProps.getProperty("storeFile")?.takeIf { it.isNotBlank() }
// Keep the release variant bound to a non-debug signing config even before validation runs. The
// nonexistent sentinel makes AGP fail too if a caller somehow bypasses validateReleaseSigning.
val configuredStoreFile = configuredStorePath?.let(rootProject::file)
    ?: rootProject.file(".release-signing-not-configured")

android {
    namespace = "com.superconnect.receiver"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.superconnect.receiver.foss"
        minSdk = 24
        targetSdk = 35
        // Same FOSS package: the successor increments code for a signer-matched in-place update.
        versionCode = 4
        versionName = "0.2.2"
    }

    signingConfigs {
        create("release") {
            storeFile = configuredStoreFile
            storePassword = keystoreProps.getProperty("storePassword") ?: ""
            keyAlias = keystoreProps.getProperty("keyAlias") ?: ""
            keyPassword = keystoreProps.getProperty("keyPassword") ?: ""
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false   // no R8: the receiver leans on reflection-free Kotlin; keep it simple
            signingConfig = signingConfigs.getByName("release")
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
    implementation(project(":core-wire"))
    testImplementation("junit:junit:4.13.2")
}

val validateReleaseSigning = tasks.register("validateReleaseSigning") {
    group = "verification"
    description = "Fails unless Android release signing inputs are complete."
    if (keystorePropsFile.isFile) inputs.file(keystorePropsFile)
    outputs.upToDateWhen { false }
    doLast {
        if (!keystorePropsFile.isFile) {
            throw GradleException("release_signing_properties_missing")
        }
        val missing = requiredReleaseSigningProperties.filter { key ->
            keystoreProps.getProperty(key).isNullOrBlank()
        }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "release_signing_properties_incomplete: missing ${missing.joinToString(",")}",
            )
        }
        if (!rootProject.file(checkNotNull(configuredStorePath)).isFile) {
            throw GradleException("release_signing_keystore_missing")
        }
    }
}

// Every release APK graph passes through a flavor-specific pre*ReleaseBuild task; debug tasks remain
// independent if a future FOSS flavor is added.
tasks.matching { it.name.startsWith("pre") && it.name.endsWith("ReleaseBuild") }.configureEach {
    dependsOn(validateReleaseSigning)
}

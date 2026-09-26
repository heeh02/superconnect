// Kotlin/JVM projection used by the ViewOnly Receiver. JNI remains the canonical frame/video/auth
// authority; no Kotlin INPUT codec is compiled in this composition.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

kotlin {
    // Use the invoking JDK (CI 17 or Android Studio JBR 21) while emitting Java 17 bytecode.
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

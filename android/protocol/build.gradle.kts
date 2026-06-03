// Pure Kotlin/JVM library: the wire protocol (FrameCodec, InputCodec, …). NO Android dependencies, so
// it is conformance-tested off-device against ../../proto/vectors.json and reused by the Android :app
// (and, on the private branch, by paid modules). `org.json` is a TEST dep only (to read the vectors).
plugins {
    id("org.jetbrains.kotlin.jvm")
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

kotlin {
    jvmToolchain(17)
}

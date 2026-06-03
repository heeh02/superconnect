// Root build file — plugin versions only (applied per-module). Android Studio's AGP Upgrade Assistant
// may offer newer versions; that's fine. Modules: :protocol (pure Kotlin/JVM), :app (Android).
plugins {
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.jvm") version "2.0.21" apply false
}

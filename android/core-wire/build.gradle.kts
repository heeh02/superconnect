plugins {
    id("com.android.library")
}

android {
    namespace = "com.superconnect.core.wire.foss"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 24
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                arguments += "-DSC_REPO_ROOT=${rootProject.projectDir.parentFile.absolutePath}"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

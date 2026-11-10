plugins {
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.nobars.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.nobars.android"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = rootProject.file("../VERSION").readText().trim()
    }

    // CI signs releases with the keystore in the ANDROID_KEYSTORE_* secrets, so
    // every release has the same signature and installs as an update. Without
    // them (local builds, forks) it falls back to the debug key.
    val keystoreFile = System.getenv("ANDROID_KEYSTORE_FILE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (keystoreFile != null) create("release") {
            storeFile = keystoreFile
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "nobars"
            keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging { resources { excludes += setOf("META-INF/versions/9/OSGI-INF/MANIFEST.MF", "META-INF/*.kotlin_module") } }
}

dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
}

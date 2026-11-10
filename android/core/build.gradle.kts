// Platform-independent NoBars protocol: packets, routing, crypto, BLE framing.
// Plain JVM so it can be unit tested without an emulator.
plugins {
    kotlin("jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    api("org.bouncycastle:bcprov-jdk18on:1.80")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    systemProperty("vectors", rootProject.file("../protocol/vectors.json").absolutePath)
    if (project.hasProperty("writeVectors")) {
        systemProperty("writeVectors", rootProject.file("../protocol/vectors-android.json").absolutePath)
        outputs.upToDateWhen { false }
    }
}

buildscript {
    dependencies {
        // AGP 9 compiles Kotlin with its built-in Kotlin support, which uses the
        // Kotlin Gradle plugin found on this classpath. Pin it so the compiler
        // matches the Compose compiler plugin below.
        classpath(libs.kotlin.gradle.plugin)
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.maven.publish) apply false
}

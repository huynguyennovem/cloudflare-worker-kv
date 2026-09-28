plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The Worker URL and optional client key, from `-PCF_CONFIG_ENDPOINT=...` or the
// CF_CONFIG_ENDPOINT environment variable (same for CF_CLIENT_KEY).
fun buildSetting(name: String): Provider<String> =
    providers.gradleProperty(name).orElse(providers.environmentVariable(name)).orElse("")

fun String.asJavaString(): String = "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "io.github.huynguyennovem.cloudflareworkerkv.example"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.huynguyennovem.cloudflareworkerkv.example"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        buildConfigField("String", "CF_CONFIG_ENDPOINT", buildSetting("CF_CONFIG_ENDPOINT").get().asJavaString())
        buildConfigField("String", "CF_CLIENT_KEY", buildSetting("CF_CLIENT_KEY").get().asJavaString())
    }

    buildTypes {
        release {
            // Shrinks the library too, proving it needs no consumer ProGuard rules.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            // So that the release build can be installed locally.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":cloudflare-worker-kv"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.activity.compose)
}

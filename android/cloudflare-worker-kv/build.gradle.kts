import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.maven.publish)
}

android {
    namespace = "io.github.huynguyennovem.cloudflareworkerkv"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // AGP 9 defaults this to compileSdk; the library uses no recent API, so do not
        // force apps onto compileSdk 36.
        aarMetadata {
            minCompileSdk = 23
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    explicitApi()
    // Compile against an older language, API and standard library than the
    // Kotlin Gradle plugin in use, so apps on Kotlin 2.1 and newer can consume
    // the library.
    coreLibrariesVersion = "2.2.10"
    compilerOptions {
        languageVersion.set(KotlinVersion.KOTLIN_2_2)
        apiVersion.set(KotlinVersion.KOTLIN_2_2)
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver3)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}

tasks.withType<Test>().configureEach {
    // The conformance tests read the shared fixtures from the repository
    // checkout; rerun them when a fixture changes.
    inputs.dir(rootProject.layout.projectDirectory.dir("../spec/fixtures"))
        .withPropertyName("specFixtures")
        .withPathSensitivity(PathSensitivity.RELATIVE)
}

mavenPublishing {
    configure(
        AndroidSingleVariantLibrary(
            javadocJar = JavadocJar.Empty(),
            sourcesJar = SourcesJar.Sources(),
            variant = "release",
        ),
    )
    coordinates("io.github.huynguyennovem", "cloudflare-worker-kv", providers.gradleProperty("VERSION_NAME").get())
    publishToMavenCentral()
    // Only sign when a key is configured (CI release); publishToMavenLocal
    // works without one.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }

    pom {
        name.set("cloudflare-worker-kv")
        description.set(
            "Remote config for Android backed by Cloudflare Workers KV: in-app defaults, " +
                "fetch and activate, typed getters and an offline cache.",
        )
        inceptionYear.set("2026")
        url.set("https://github.com/huynguyennovem/cloudflare-worker-kv/tree/main/android")
        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("huynguyennovem")
                name.set("huynguyennovem")
                url.set("https://github.com/huynguyennovem")
            }
        }
        scm {
            url.set("https://github.com/huynguyennovem/cloudflare-worker-kv")
            connection.set("scm:git:git://github.com/huynguyennovem/cloudflare-worker-kv.git")
            developerConnection.set("scm:git:ssh://git@github.com/huynguyennovem/cloudflare-worker-kv.git")
        }
    }
}

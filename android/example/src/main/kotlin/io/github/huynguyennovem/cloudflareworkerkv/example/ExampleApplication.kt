package io.github.huynguyennovem.cloudflareworkerkv.example

import android.app.Application
import io.github.huynguyennovem.cloudflareworkerkv.CloudflareRemoteConfig
import io.github.huynguyennovem.cloudflareworkerkv.remoteConfigSettings
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.async

class ExampleApplication : Application() {
    private val appScope = MainScope()

    /**
     * The shared remote config, ready once initialized, with settings and defaults applied.
     * `null` when the example was built without an endpoint.
     */
    var remoteConfig: Deferred<CloudflareRemoteConfig>? = null
        private set

    override fun onCreate() {
        super.onCreate()
        val endpoint = BuildConfig.CF_CONFIG_ENDPOINT
        if (endpoint.isEmpty()) return

        remoteConfig = appScope.async {
            val remoteConfig = CloudflareRemoteConfig.initialize(
                this@ExampleApplication,
                endpoint = endpoint,
                clientKey = BuildConfig.CF_CLIENT_KEY.ifEmpty { null },
            )
            remoteConfig.setConfigSettings(
                remoteConfigSettings {
                    fetchTimeout = 10.seconds
                    // Use a long interval (e.g. 1 hour) in production.
                    minimumFetchInterval = Duration.ZERO
                },
            )
            remoteConfig.setDefaults(
                mapOf(
                    "welcome_message" to "Hello from defaults",
                    "max_items" to 5,
                    "discount_ratio" to 0.0,
                    "new_checkout_enabled" to false,
                ),
            )
            remoteConfig
        }
    }
}

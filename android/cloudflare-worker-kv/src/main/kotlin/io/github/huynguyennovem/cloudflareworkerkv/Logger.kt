package io.github.huynguyennovem.cloudflareworkerkv

import android.util.Log

/**
 * Receives the warnings of the library (storage failures, ignored caches). Messages never
 * contain the client key or config values.
 */
internal fun interface Logger {
    fun warn(message: String, throwable: Throwable?)

    companion object {
        private const val TAG = "CloudflareWorkerKv"

        val ANDROID: Logger = Logger { message, throwable -> Log.w(TAG, message, throwable) }
    }
}

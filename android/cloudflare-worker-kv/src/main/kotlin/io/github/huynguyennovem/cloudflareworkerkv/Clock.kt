package io.github.huynguyennovem.cloudflareworkerkv

/** Source of the current time, injectable for tests. */
internal fun interface Clock {
    /** Milliseconds since the epoch. */
    fun nowMillis(): Long

    companion object {
        val SYSTEM: Clock = Clock { System.currentTimeMillis() }
    }
}

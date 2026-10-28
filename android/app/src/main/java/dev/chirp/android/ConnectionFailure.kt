package dev.chirp.android

import android.content.res.Resources
import androidx.annotation.StringRes
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** Why the Mac couldn't be reached, from exception classes only: messages can carry hosts and are never read.
 * Wording is hedged because Android reports the symptom, not the cause. */
internal object ConnectionFailure {
    internal enum class Kind(@StringRes val id: Int, val offline: Boolean) : DictationStatus {
        DNS(R.string.status_failure_dns, true),
        DOWN(R.string.status_failure_down, true),
        TLS(R.string.status_failure_tls, false),
        OTHER(R.string.status_failure_other, false);
        override fun resolve(resources: Resources): String = resources.getString(id)
        // TLS has no Tailscale fix; the status text alone explains it.
        override val action get() = DictationAction.NETWORK.takeUnless { this == TLS }
        override val error get() = true
        // "Can't find…" and "asleep" say more than the fix does; "unreachable" says nothing the fix doesn't.
        override val named get() = offline
    }

    internal fun classify(failure: Throwable?): Kind {
        var current = failure
        repeat(6) {
            when (current) {
                null -> return Kind.OTHER
                is UnknownHostException -> return Kind.DNS
                is SSLException -> return Kind.TLS
                is InterruptedIOException, is ConnectException, is NoRouteToHostException -> return Kind.DOWN
                else -> current = current?.cause
            }
        }
        return Kind.OTHER
    }
    /** A deadline expiring before Ready is a connect timeout when the transport recorded no better reason. */
    internal fun status(kind: Kind?, timedOut: Boolean = false): Kind =
        if (kind == null || kind == Kind.OTHER) (if (timedOut) Kind.DOWN else Kind.OTHER) else kind
}

/** The last health/prewarm outcome. Offline only for a short window: a Mac that woke up must not stay marked down. */
internal class OfflineState(private val now: () -> Long = android.os.SystemClock::elapsedRealtime, private val window: Long = 30000) {
    private var at = -1L
    var kind = ConnectionFailure.Kind.OTHER
        private set
    fun failed(kind: ConnectionFailure.Kind) { if (kind.offline) { at = now(); this.kind = kind } else reachable() }
    fun reachable() { at = -1L; kind = ConnectionFailure.Kind.OTHER }
    fun active() = at >= 0 && now() - at < window
    /** Milliseconds until active() turns false; 0 when it already is. */
    fun remaining() = if (active()) window - (now() - at) else 0L
}

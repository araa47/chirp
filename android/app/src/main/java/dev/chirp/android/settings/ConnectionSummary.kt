package dev.chirp.android.settings

import dev.chirp.android.Health
import dev.chirp.android.R
import dev.chirp.android.UiText
import dev.chirp.android.cleanupAvailable
import dev.chirp.android.ui.StatusKind

internal class ConnectionSummary(val kind: StatusKind, val title: UiText, val summary: UiText?, val hint: UiText? = null)

/** What the Mac connection row says. [reachable] is null until a check has finished (the keyboard's summary never checks). */
internal fun connectionSummary(paired: Boolean, host: String, reachable: Boolean?, checking: Boolean, health: Health?): ConnectionSummary {
    if (!paired) return ConnectionSummary(StatusKind.Warning, UiText.Res(R.string.connection_not_paired), UiText.Res(R.string.settings_summary_pair))
    val details = UiText.Res(R.string.connection_details, health?.engine ?: UiText.Res(R.string.connection_engine_missing), when {
        !health.cleanupAvailable() -> UiText.Res(R.string.connection_cleanup_off)
        health?.correctionLeavesMachine == true -> UiText.Res(R.string.connection_cleanup_via, health.correctionHost.orEmpty())
        else -> UiText.Res(R.string.connection_cleanup_computer)
    })
    return when {
        checking -> ConnectionSummary(StatusKind.Info, UiText.Res(R.string.connection_checking, host), details)
        reachable == false -> ConnectionSummary(StatusKind.Warning, UiText.Res(R.string.connection_unreachable, host), details,
            UiText.Res(R.string.connection_unreachable_hint))
        health?.ready == false -> ConnectionSummary(StatusKind.Info, UiText.Res(R.string.connection_paired, host), UiText.Res(R.string.connection_loading_model))
        reachable == true -> ConnectionSummary(StatusKind.Success, UiText.Res(R.string.connection_connected, host), details)
        else -> ConnectionSummary(StatusKind.Info, UiText.Res(R.string.connection_paired, host), details)
    }
}

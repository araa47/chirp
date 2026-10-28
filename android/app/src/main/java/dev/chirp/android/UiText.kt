package dev.chirp.android

import android.content.res.Resources
import androidx.annotation.PluralsRes
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalResources

/**
 * Text a model or state class hands to the UI (#339). Models keep the resource and its arguments, never the English,
 * so logic matches on types and the words are resolved only where they are shown. Arguments that are themselves
 * [UiText] are resolved first.
 */
internal sealed interface UiText {
    fun resolve(resources: Resources): String

    data class Res(@StringRes val id: Int, val args: List<Any> = emptyList()) : UiText {
        constructor(@StringRes id: Int, vararg args: Any) : this(id, args.toList())
        override fun resolve(resources: Resources): String =
            if (args.isEmpty()) resources.getString(id) else resources.getString(id, *resolved(resources, args))
    }

    data class Plural(@PluralsRes val id: Int, val count: Int, val args: List<Any> = listOf(count)) : UiText {
        override fun resolve(resources: Resources): String = resources.getQuantityString(id, count, *resolved(resources, args))
    }

    /** Text that is never translated: what the user typed or said, file names, server-provided names. */
    data class Raw(val value: String) : UiText {
        override fun resolve(resources: Resources) = value
    }

    private companion object {
        fun resolved(resources: Resources, args: List<Any>) = args.map { if (it is UiText) it.resolve(resources) else it }.toTypedArray()
    }
}

@Composable @ReadOnlyComposable
internal fun UiText.text(): String = resolve(LocalResources.current)

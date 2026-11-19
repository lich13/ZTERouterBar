package com.zte.routerbar.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily

private val LightColors = lightColorScheme(
    primary = Color(0xFF0E5AA7),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E6FF),
    onPrimaryContainer = Color(0xFF001B3D),
    secondary = Color(0xFF3E607C),
    secondaryContainer = Color(0xFFD6E4F3),
    surface = Color(0xFFF8FAFC),
    surfaceVariant = Color(0xFFEAEFF6),
    background = Color(0xFFF3F6FA)
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF8CC4FF),
    onPrimary = Color(0xFF003060),
    primaryContainer = Color(0xFF004788),
    onPrimaryContainer = Color(0xFFD6E6FF),
    secondary = Color(0xFFA6C8E6),
    secondaryContainer = Color(0xFF264762),
    surface = Color(0xFF11161D),
    surfaceVariant = Color(0xFF1D2530),
    background = Color(0xFF0C1016)
)

@Composable
fun ZteRouterBarTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    val colors = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else {
        if (darkTheme) DarkColors else LightColors
    }
    MaterialTheme(
        colorScheme = colors,
        content = content
    )
}

@Composable
fun toneColor(tone: MetricTone, darkTheme: Boolean = isSystemInDarkTheme()): Color = when (tone) {
    MetricTone.EXCELLENT -> if (darkTheme) Color(0xFF4ADE80) else Color(0xFF15803D)
    MetricTone.GOOD -> if (darkTheme) Color(0xFF60A5FA) else Color(0xFF1D4ED8)
    MetricTone.FAIR -> if (darkTheme) Color(0xFFFBBF24) else Color(0xFFD97706)
    MetricTone.POOR -> if (darkTheme) Color(0xFFF87171) else Color(0xFFDC2626)
    MetricTone.NEUTRAL -> MaterialTheme.colorScheme.onSurfaceVariant
}

/**
 * Enforces tabular numerals (`tnum`) on numeric metrics while preserving the system UI font,
 * matching the macOS `monospacedDigit()` typography spec.
 */
fun TextStyle.tabularNums(): TextStyle = copy(
    fontFamily = FontFamily.Default,
    fontFeatureSettings = "tnum"
)

package com.zte.routerbar.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zte.routerbar.core.SignalRatingAssessment
import com.zte.routerbar.core.SignalSample

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SignalQualityChartCard(
    assessment: SignalRatingAssessment,
    samples: List<SignalSample>,
    signalBars: Int?,
    selectedMetric: SignalChartMetric,
    onSelectMetric: (SignalChartMetric) -> Unit,
    modifier: Modifier = Modifier
) {
    val gradeTone = Formatters.gradeTone(assessment.grade)
    val lineColor = toneColor(gradeTone)

    val plottedValues = remember(samples, selectedMetric) {
        samples.mapNotNull { sample ->
            val v = when (selectedMetric) {
                SignalChartMetric.RSRP -> sample.rsrp
                SignalChartMetric.SINR -> sample.sinr
                SignalChartMetric.SCORE -> sample.score.toDouble()
            }
            v?.let { sample.timestampMs to it }
        }
    }

    ElevatedCard(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = "信号强度评级",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.align(Alignment.CenterVertically)
                )
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterVertically)
                        .clip(CircleShape)
                        .background(lineColor)
                        .padding(horizontal = 9.dp, vertical = 3.dp)
                ) {
                    Text(
                        text = assessment.grade.label,
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                        color = Color.White
                    )
                }
                Text(
                    text = "${assessment.score} / 100",
                    style = MaterialTheme.typography.bodyMedium.tabularNums().copy(fontWeight = FontWeight.SemiBold),
                    color = lineColor,
                    modifier = Modifier.align(Alignment.CenterVertically)
                )
                if (signalBars != null) {
                    Text(
                        text = "格数 $signalBars/5",
                        style = MaterialTheme.typography.labelMedium.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.align(Alignment.CenterVertically)
                    )
                }
            }

            Text(
                text = "${assessment.primaryTechLabel} · ${assessment.adviceText}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Full-width segmented metric selector with complete rectangular touch targets
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(3.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    SignalChartMetric.entries.forEach { metric ->
                        val selected = (metric == selectedMetric)
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .weight(1f)
                                .heightIn(min = LayoutSpec.TOOLBAR_CONTROL_HEIGHT_DP.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    if (selected) MaterialTheme.colorScheme.primaryContainer
                                    else Color.Transparent
                                )
                                .clickable { onSelectMetric(metric) }
                                .padding(horizontal = 6.dp, vertical = 6.dp)
                        ) {
                            Text(
                                text = metric.label,
                                style = MaterialTheme.typography.labelMedium.copy(
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                                ),
                                color = if (selected) {
                                    MaterialTheme.colorScheme.onPrimaryContainer
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }

            if (plottedValues.isEmpty()) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(140.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                ) {
                    Text(
                        text = "正在等待该指标的轮询采样数据…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                val valuesOnly = plottedValues.map { it.second }
                val (yMin, yMax) = LayoutSpec.chartYDomain(selectedMetric, valuesOnly)
                val thresholds = LayoutSpec.chartThresholds(selectedMetric)
                val gridColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
                val thresholdColors = thresholds.map { toneColor(it.tone).copy(alpha = 0.55f) }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(LayoutSpec.CHART_HEIGHT_DP.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(
                        modifier = Modifier
                            .width(LayoutSpec.CHART_Y_AXIS_WIDTH_DP.dp)
                            .height(LayoutSpec.CHART_HEIGHT_DP.dp)
                            .padding(end = 4.dp),
                        verticalArrangement = Arrangement.SpaceBetween,
                        horizontalAlignment = Alignment.End
                    ) {
                        val mid = (yMin + yMax) / 2.0
                        listOf(yMax, mid, yMin).forEach { tick ->
                            Text(
                                text = tick.toInt().toString(),
                                style = MaterialTheme.typography.labelSmall.tabularNums(),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1
                            )
                        }
                    }

                    Canvas(
                        modifier = Modifier
                            .weight(1f)
                            .height(LayoutSpec.CHART_HEIGHT_DP.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.25f))
                    ) {
                        val padH = 10.dp.toPx()
                        val padV = 12.dp.toPx()
                        val plotW = (size.width - padH * 2f).coerceAtLeast(1f)
                        val plotH = (size.height - padV * 2f).coerceAtLeast(1f)
                        val spanY = (yMax - yMin).coerceAtLeast(1.0)

                        fun mapY(v: Double): Float {
                            val ratio = ((v - yMin) / spanY).coerceIn(0.0, 1.0).toFloat()
                            return padV + plotH * (1f - ratio)
                        }

                        // Horizontal grid lines
                        listOf(0f, 0.5f, 1f).forEach { frac ->
                            val y = padV + plotH * frac
                            drawLine(
                                color = gridColor,
                                start = Offset(padH, y),
                                end = Offset(padH + plotW, y),
                                strokeWidth = 1.dp.toPx()
                            )
                        }

                        // Dashed threshold lines
                        val dash = PathEffect.dashPathEffect(floatArrayOf(10f, 10f), 0f)
                        thresholds.forEachIndexed { idx, th ->
                            if (th.value in yMin..yMax) {
                                val y = mapY(th.value)
                                drawLine(
                                    color = thresholdColors[idx],
                                    start = Offset(padH, y),
                                    end = Offset(padH + plotW, y),
                                    strokeWidth = 1.2.dp.toPx(),
                                    pathEffect = dash
                                )
                            }
                        }

                        val count = plottedValues.size
                        val tMin = plottedValues.first().first
                        val tMax = plottedValues.last().first
                        val tSpan = tMax - tMin
                        val coords = plottedValues.mapIndexed { idx, (ts, value) ->
                            val x = when {
                                count == 1 -> padH + plotW * 0.5f
                                tSpan > 0L -> padH + plotW * ((ts - tMin).toFloat() / tSpan.toFloat())
                                else -> padH + plotW * (idx.toFloat() / (count - 1).toFloat())
                            }
                            x to mapY(value)
                        }

                        if (coords.size >= 2) {
                            val segments = LayoutSpec.computeMonotoneCubicSegments(coords)
                            val linePath = Path().apply {
                                moveTo(segments.first().x0, segments.first().y0)
                                for (seg in segments) {
                                    cubicTo(seg.cx1, seg.cy1, seg.cx2, seg.cy2, seg.x1, seg.y1)
                                }
                            }
                            val baselineY = padV + plotH
                            val areaPath = Path().apply {
                                addPath(linePath)
                                lineTo(segments.last().x1, baselineY)
                                lineTo(segments.first().x0, baselineY)
                                close()
                            }
                            drawPath(
                                path = areaPath,
                                brush = Brush.verticalGradient(
                                    colors = listOf(lineColor.copy(alpha = 0.28f), lineColor.copy(alpha = 0.02f)),
                                    startY = padV,
                                    endY = baselineY
                                )
                            )
                            drawPath(
                                path = linePath,
                                color = lineColor,
                                style = Stroke(
                                    width = 2.2.dp.toPx(),
                                    cap = StrokeCap.Round,
                                    join = StrokeJoin.Round
                                )
                            )
                        }

                        if (coords.size <= 2) {
                            coords.forEachIndexed { idx, pt ->
                                val r = if (idx == coords.lastIndex) 4.dp.toPx() else 3.dp.toPx()
                                drawCircle(
                                    color = lineColor,
                                    radius = r,
                                    center = Offset(pt.first, pt.second)
                                )
                            }
                        } else {
                            val lastPt = coords.last()
                            drawCircle(
                                color = lineColor,
                                radius = 4.dp.toPx(),
                                center = Offset(lastPt.first, lastPt.second)
                            )
                        }
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = LayoutSpec.CHART_Y_AXIS_WIDTH_DP.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = Formatters.timeOfDay(plottedValues.first().first),
                        style = MaterialTheme.typography.labelSmall.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                    Text(
                        text = "基准: ${thresholds.joinToString(" / ") { it.label }}",
                        style = MaterialTheme.typography.labelSmall.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    if (plottedValues.size > 1) {
                        Text(
                            text = Formatters.timeOfDay(plottedValues.last().first),
                            style = MaterialTheme.typography.labelSmall.tabularNums(),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1
                        )
                    }
                }

                val minV = valuesOnly.minOrNull() ?: 0.0
                val maxV = valuesOnly.maxOrNull() ?: 0.0
                val lastV = valuesOnly.last()
                val avgV = valuesOnly.average()

                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    ChartStatChip("最新", Formatters.metricChartValue(selectedMetric, lastV))
                    ChartStatChip("平均", Formatters.metricChartValue(selectedMetric, avgV))
                    ChartStatChip("最低", Formatters.metricChartValue(selectedMetric, minV))
                    ChartStatChip("最高", Formatters.metricChartValue(selectedMetric, maxV))
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "最近 ${plottedValues.size} 次采样",
                        style = MaterialTheme.typography.labelSmall.tabularNums(),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun ChartStatChip(title: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "$title: ",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.labelSmall.tabularNums().copy(fontWeight = FontWeight.Medium),
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

package com.zte.routerbar.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zte.routerbar.core.AuthHashPreference
import com.zte.routerbar.data.StoredAppSettings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileConfigSheet(
    uiState: RouterUiState,
    viewModel: RouterViewModel
) {
    if (!uiState.isProfileSheetOpen) return

    BackHandler(enabled = true) {
        viewModel.requestCloseProfileSheet()
    }

    // Material3 keys the sheet state on this lambda instance, so it must not capture uiState:
    // a new instance per emission rebuilds the state as Hidden and replays the slide-in on every poll.
    val confirmSheetValueChange: (SheetValue) -> Boolean = remember(viewModel) {
        { target: SheetValue ->
            val state = viewModel.uiState.value
            when {
                target != SheetValue.Hidden -> true
                // requestCloseProfileSheet() ignores closes while saving; hiding here would leave
                // an invisible sheet that still blocks the screen.
                state.isSavingProfile -> false
                state.hasUnsavedDraftChanges -> {
                    viewModel.requestCloseProfileSheet()
                    false
                }
                else -> true
            }
        }
    }
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = confirmSheetValueChange
    )

    if (uiState.showDiscardDialog) {
        AlertDialog(
            onDismissRequest = { viewModel.dismissDiscardDialog() },
            title = { Text("放弃未保存修改？") },
            text = { Text("当前配置包含未保存的改动，关闭后将丢弃这些修改。") },
            confirmButton = {
                TextButton(onClick = { viewModel.confirmDiscardProfileChanges() }) {
                    Text("放弃修改", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.dismissDiscardDialog() }) {
                    Text("继续编辑")
                }
            }
        )
    }

    ModalBottomSheet(
        onDismissRequest = { viewModel.requestCloseProfileSheet() },
        sheetState = sheetState
    ) {
        var showPasswordPlain by rememberSaveable(uiState.editingProfileId) { mutableStateOf(false) }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .imePadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "路由器配置与轮询设置",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = { viewModel.requestCloseProfileSheet() }) {
                    Text("关闭")
                }
            }

            // Polling interval & zero-permission gateway auto-match
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text(
                        text = "前台轮询间隔",
                        style = MaterialTheme.typography.labelLarge
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        StoredAppSettings.ALLOWED_POLL_INTERVALS.forEach { sec ->
                            val selected = (uiState.pollingIntervalSec == sec)
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .weight(1f)
                                    .heightIn(min = 40.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(
                                        if (selected) MaterialTheme.colorScheme.primaryContainer
                                        else MaterialTheme.colorScheme.surface
                                    )
                                    .clickable { viewModel.setPollingIntervalSec(sec) }
                            ) {
                                Text(
                                    text = "${sec}s",
                                    style = MaterialTheme.typography.bodyMedium.tabularNums().copy(
                                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                                    ),
                                    color = if (selected) {
                                        MaterialTheme.colorScheme.onPrimaryContainer
                                    } else {
                                        MaterialTheme.colorScheme.onSurface
                                    }
                                )
                            }
                        }
                    }

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = LayoutSpec.MIN_TOUCH_TARGET_DP.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { viewModel.setAutoMatchByGateway(!uiState.autoMatchByGateway) }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "按当前 Wi-Fi 网关自动匹配配置",
                                style = MaterialTheme.typography.bodyMedium
                            )
                            Text(
                                text = uiState.wifiGatewayIp?.let { "当前检测网关：$it（无需定位权限）" }
                                    ?: "当前未检测到局域网 IPv4 网关",
                                style = MaterialTheme.typography.labelSmall.tabularNums(),
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = uiState.autoMatchByGateway,
                            onCheckedChange = null
                        )
                    }
                }
            }

            // Saved profiles list
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "已保存配置 (${uiState.profiles.size})",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f)
                )
                OutlinedButton(onClick = { viewModel.addNewProfileDraft() }) {
                    Text("+ 新增配置")
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                uiState.profiles.forEach { profile ->
                    val isActive = profile.id == uiState.activeProfileId
                    val isEditing = profile.id == uiState.editingProfileId
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = if (isEditing) {
                            MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f)
                        } else {
                            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .clickable { viewModel.selectProfileForEditing(profile.id) }
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    Text(
                                        text = profile.name,
                                        style = MaterialTheme.typography.bodyMedium.copy(
                                            fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal
                                        ),
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    if (isActive) {
                                        Text(
                                            text = "当前使用",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.primary
                                        )
                                    }
                                }
                                Text(
                                    text = profile.routerUrlString,
                                    style = MaterialTheme.typography.labelSmall.tabularNums(),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }

                            if (!isActive) {
                                OutlinedButton(onClick = { viewModel.selectProfileFromSheet(profile.id) }) {
                                    Text("切换")
                                }
                            }

                            if (uiState.profiles.size > 1) {
                                TextButton(
                                    onClick = { viewModel.deleteProfile(profile.id) },
                                    colors = ButtonDefaults.textButtonColors(
                                        contentColor = MaterialTheme.colorScheme.error
                                    )
                                ) {
                                    Text("删除")
                                }
                            }
                        }
                    }
                }
                if (uiState.isEditingUnsavedNewProfile) {
                    Surface(
                        shape = RoundedCornerShape(10.dp),
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "${uiState.draftName.ifBlank { "新路由器配置" }}（未保存草稿）",
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Text(
                                    text = uiState.draftUrl.ifBlank { "http://192.168.8.1" },
                                    style = MaterialTheme.typography.labelSmall.tabularNums(),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }
            }

            HorizontalDivider()

            // Selected profile editor
            Text(
                text = if (uiState.isEditingUnsavedNewProfile) "新增配置详情" else "编辑配置详情",
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
            )

            OutlinedTextField(
                value = uiState.draftName,
                onValueChange = viewModel::updateDraftName,
                label = { Text("配置名称") },
                placeholder = { Text("例如：随身 5G 热点 / 客厅 CPE") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = uiState.draftUrl,
                    onValueChange = viewModel::updateDraftUrl,
                    label = { Text("管理后台地址") },
                    placeholder = { Text("http://192.168.8.1") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.weight(1f)
                )
                if (!uiState.wifiGatewayIp.isNullOrBlank()) {
                    OutlinedButton(
                        onClick = { viewModel.fillCurrentGatewayIntoDraft() },
                        modifier = Modifier
                            .padding(top = 6.dp)
                            .heightIn(min = LayoutSpec.MIN_TOUCH_TARGET_DP.dp)
                    ) {
                        Text("填入网关")
                    }
                }
            }

            OutlinedTextField(
                value = uiState.draftPassword,
                onValueChange = viewModel::updateDraftPassword,
                label = { Text("管理密码 (Android Keystore AES-GCM 加密)") },
                singleLine = true,
                visualTransformation = if (showPasswordPlain) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    TextButton(onClick = { showPasswordPlain = !showPasswordPlain }) {
                        Text(if (showPasswordPlain) "隐藏" else "显示")
                    }
                },
                modifier = Modifier.fillMaxWidth()
            )

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "AD 签名算法",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                AuthHashPreference.entries.forEach { algo ->
                    val selected = (uiState.draftHashPreference == algo)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 42.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(
                                if (selected) MaterialTheme.colorScheme.primaryContainer
                                else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                            )
                            .clickable { viewModel.updateDraftHashPreference(algo) }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = algo.displayName,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                            ),
                            color = if (selected) {
                                MaterialTheme.colorScheme.onPrimaryContainer
                            } else {
                                MaterialTheme.colorScheme.onSurface
                            },
                            modifier = Modifier.weight(1f)
                        )
                        if (selected) {
                            Text(
                                text = "✓",
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
            }

            uiState.lastError?.let { errorMsg ->
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = errorMsg,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (uiState.draftHasStoredPassword) {
                    OutlinedButton(
                        onClick = { viewModel.clearDraftProfilePassword() },
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = MaterialTheme.colorScheme.error
                        )
                    ) {
                        Text("清除密码")
                    }
                }
                Spacer(modifier = Modifier.weight(1f))
                Button(
                    onClick = { viewModel.saveDraftAndActivate() },
                    enabled = !uiState.isSavingProfile &&
                        uiState.draftUrl.trim().isNotEmpty() &&
                        (uiState.draftPassword.trim().isNotEmpty() || uiState.draftHasStoredPassword)
                ) {
                    Text(if (uiState.isSavingProfile) "保存连接中…" else "保存并测试连接")
                }
            }
        }
    }
}

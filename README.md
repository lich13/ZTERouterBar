# ZTERouterBar

基于 **Swift 6 + SwiftUI + AppKit** 的中兴（ZTE）移动热点 / 5G CPE macOS 状态栏助手，支持一键重连外网、实时信号与终端监控，以及多路由器配置的 Wi-Fi 名自动匹配切换。

## 核心特性

- **零确认一键重连外网**
  - 点击状态栏弹窗的「重连外网」按钮
  - **`⌥ + 左键` 点击状态栏图标**直接触发重连
  - **全局快捷键 `⌃⌥W`** 或右键菜单一键重连（无需弹窗确认）
  - 执行 `DISCONNECT_NETWORK` → 等待断开 → `CONNECT_NETWORK` → 等待重新拨号成功
- **状态栏信号强度、评级、趋势曲线与终端监控**
  - 状态栏默认直接显示信号强度（如 `-69dBm 极佳`），综合 RSRP / SINR / RSRQ 输出 0–100 综合信号评级，并在概览页与弹窗展示实时信号变化曲线
  - 通过 `wifi_access_sta_num` 与按需查询 `station_list` / `lan_station_list`（不带 `multi_data=1`）准确获取无线/有线终端数量及设备列表
  - 展示 5G NR / 4G LTE / 3G UMTS 信号指标（RSRP / SINR / RSRQ / PCI / 频段与带宽）、邻区、温度与连接/月度流量统计
- **多路由器配置 & Wi-Fi 名称自动匹配**
  - 支持保存多个路由器配置（名称、地址、管理密码、AD 算法、绑定多个 Wi-Fi SSID）
  - 使用 `CoreWLAN` + `CoreLocation` 识别当前连接的 Wi-Fi 名称，自动切换对应配置与钥匙串凭据
- **外网限流自动保活守护（Watchdog）与系统通知**
  - 打开 App 默认自动启动保活守护，以 `https://661313.xyz/test/generate_204`（权重 `3`，`15s` / `3s`）为主节点并搭配 `YouTube 204` / `Cloudflare DoH`（权重 `1`，`33s` / `4s`），支持每个端点独立配置检测频率（`s`）、超时（`s`）与权重，连续不通 `2` 次立即重连
  - 触发自动重连及每次手动/自动重连前后的 WAN IPv4/IPv6 变化均自动推送 macOS 系统通知

## 本地构建与测试

```bash
swift test
PACKAGE_DMG=1 APP_VERSION=1.0.0 ./scripts/build-app.sh release
```

## 隐私说明

- 所有路由器管理密码均通过 macOS 钥匙串（`Keychain`）加密存储，不写入源码或明文配置。
- Wi-Fi 名称仅在本地用于匹配已保存配置，不会上传到任何第三方服务器。

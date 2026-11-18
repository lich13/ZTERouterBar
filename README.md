# ZTERouterBar

基于 **Swift 6 + SwiftUI + AppKit** 的中兴（ZTE）移动热点 / 5G CPE macOS 状态栏助手，支持一键重连外网、实时信号与终端监控，以及多路由器配置的 Wi-Fi 名自动匹配切换。

## 核心特性

- **零确认一键重连外网**
  - 点击状态栏弹窗的「重连外网」按钮
  - **`⌥ + 左键` 点击状态栏图标**直接触发重连
  - **全局快捷键 `⌃⌥W`** 或右键菜单一键重连（无需弹窗确认）
  - 执行 `DISCONNECT_NETWORK` → 等待断开 → `CONNECT_NETWORK` → 等待重新拨号成功
- **实时信号与终端监控**
  - 通过 `wifi_access_sta_num` 与单独查询 `station_list` / `lan_station_list`（不带 `multi_data=1`）准确获取无线/有线终端数量及设备列表
  - 展示 5G NR / 4G LTE / 3G UMTS 信号指标（RSRP / SINR / RSRQ / PCI / 频段与带宽）、邻区、温度、实时速率与流量统计
- **多路由器配置 & Wi-Fi 名称自动匹配**
  - 支持保存多个路由器配置（名称、地址、管理密码、AD 算法、绑定多个 Wi-Fi SSID）
  - 使用 `CoreWLAN` + `CoreLocation` 识别当前连接的 Wi-Fi 名称，自动切换对应配置与钥匙串凭据
- **外网限流自动保活守护（Watchdog）**
  - 打开 App 默认自动启动保活守护，定时并发探测可编辑的目标链接（默认预设 Cloudflare / Google / Apple 204，跟随系统代理；单端点支持独立配置跟随系统代理 / 直连 / HTTP / SOCKS5）
  - 全部启用端点不可达并经防抖复检确认后，自动执行外网重连与重连后复检确认，支持连续重连冷却保护

## 本地构建与测试

```bash
swift test
PACKAGE_DMG=1 APP_VERSION=1.0.0 ./scripts/build-app.sh release
```

## 隐私说明

- 所有路由器管理密码均通过 macOS 钥匙串（`Keychain`）加密存储，不写入源码或明文配置。
- Wi-Fi 名称仅在本地用于匹配已保存配置，不会上传到任何第三方服务器。

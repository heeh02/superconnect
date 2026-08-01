# superconnect_free

`superconnect_free` 是免费基础版：将 Mac 画面投到 HarmonyOS 或 Android 平板，平板作为 Mac 的扩展屏使用。

免费版的使用方式是 **Mac 作为画面源，平板作为接收端**，支持 USB 有线和局域网 Wi-Fi 连接。

## 下载

打开 [GitHub Releases](https://github.com/heeh02/superconnect/releases)：

- Apple Silicon（M 系列）Mac：下载 `macos-free.app.zip`。
- Intel Mac：下载 `macos-intel-x86_64.app.zip`。
- Android 平板：下载免费版 APK。
- HarmonyOS 平板：从应用市场搜索 `superconnect` 安装；测试包按发布页提供的免费版 HAP 安装。

Mac 免费版应用名称为 `superconnect_free`，平板端应用名称为 `superconnect`。

## 安装

### Mac

1. 解压下载的 ZIP，将 `superconnect_free.app` 拖入“应用程序”。
2. 首次打开时，右键 App，选择“打开”，再确认一次。
3. 在系统设置“隐私与安全性”中授予“屏幕录制”和“辅助功能”权限。

如果 macOS 阻止打开，可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/superconnect_free.app
```

### HarmonyOS 平板

- 应用市场安装：直接搜索并安装 `superconnect`。
- 测试 HAP 侧载：需要使用有效签名，并按设备要求开启开发者模式。
- USB 有线连接还需要开启 USB 调试，并在首次连接时信任 Mac。

### Android 平板

1. 安装 Releases 中的免费版 APK。
2. USB 有线连接时开启 USB 调试，并在首次连接时允许 Mac 的 RSA 授权。
3. Wi-Fi 连接不需要 USB 调试，但 Mac 与平板必须连接到同一个局域网。

## 使用

### USB 有线

1. 在平板上打开 `superconnect`。
2. 使用可传输数据的 USB-C 线连接 Mac 与平板。
3. 在 Mac 上打开 `superconnect_free`，选择设备并点击“开始连接”。

HarmonyOS 使用 HDC 连接，Android 使用 ADB 连接；Mac 发行包已包含免费版有线连接所需工具。

### Wi-Fi 无线

1. Mac 与平板连接到同一个局域网。
2. 在平板端打开 `superconnect` 并开启无线模式。
3. 在 Mac 端打开 `superconnect_free`，选择自动发现的设备；也可以使用平板显示的 IP 手动连接。

## 常见问题

- 找不到设备：有线连接检查数据线、USB 调试和设备授权；无线连接检查双方是否在同一局域网。
- 没有画面：确认平板端 App 正在前台运行，并重新连接一次。
- Mac 无法开始投屏：确认已授予“屏幕录制”和“辅助功能”权限。

具体平台的构建和测试说明：[`android/README.md`](android/README.md) · [`harmony/README.md`](harmony/README.md)

## 许可证

[MIT](LICENSE)

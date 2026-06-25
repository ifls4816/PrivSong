# PrivSong 项目记忆

## 项目信息
- **中文名称**：私音
- **英文名称**：PrivSong
- **类型**：iOS SwiftUI 应用
- **用途**：Emby 音乐客户端
- **最低系统**：iOS 26+
- **Bundle ID**：local.ifls.PrivSong
- **开发团队**：UPD89D99AH
- **Swift 版本**：6.0

## 项目结构
- `PrivSong/` — 主源码目录
- `PrivSong.xcodeproj/` — Xcode 工程
- 源码模块：Models / Networking / Playback / Store / Views / CarPlay

## 命名约定
- 项目原名 `ios-music`，已全局重命名为 `PrivSong`
- 中文显示名：私音（通过 zh-Hans.lproj/InfoPlist.strings 本地化）
- 英文显示名：PrivSong（Info.plist 默认值 + en.lproj/InfoPlist.strings）

## App 显示名称本地化
- `${SRCROOT}/PrivSong/Info.plist` → `CFBundleDisplayName = "PrivSong"`（默认）
- `${SRCROOT}/PrivSong/zh-Hans.lproj/InfoPlist.strings` → `CFBundleDisplayName = "私音"`（中文）
- `${SRCROOT}/PrivSong/en.lproj/InfoPlist.strings` → `CFBundleDisplayName = "PrivSong"`（英文）
- 不要在 Build Settings 中设 `INFOPLIST_KEY_CFBundleDisplayName`，会覆盖本地化

# YouTube Music 风格独立播放页

本示例根据需求中的文字规格实现。对话中没有可读取的截图附件，因此不能声称与截图像素级一致。没有修改主项目入口、现有播放器路由或播放服务。

## 项目结构与放置位置

主项目使用模块化结构：

```text
lib/
├── main.dart                 # 应用启动、权限、音频等初始化
├── app.dart                  # 应用壳
├── core/                     # 基础设施、布局、主题与服务
├── data/                     # 模型与仓库
├── modules/player/           # 完整/迷你播放器、路由及播放控制
├── providers/                # 播放、主题等共享状态
├── services/                 # 接口与服务
└── widgets/                  # 歌词、封面、进度条等复用组件
examples/youtube_music_player/
├── lib/main.dart             # 完整单文件：入口、主题、页面和全部辅助组件
├── test/player_test.dart     # 布局和交互测试
├── web/index.html            # Web 启动壳
└── pubspec.yaml              # 仅依赖 Flutter SDK
```

现有应用使用 `material_ui` 及多项原生插件；此示例特意使用标准 `package:flutter/material.dart`，作为独立 package 运行，不依赖主应用的 Provider、服务或资源。不建议直接替换主项目 `lib/main.dart`。

## 运行

需要 Flutter >= 3.22.0 / Dart >= 3.4.0。

```bash
cd examples/youtube_music_player
flutter pub get
flutter run -d chrome
```

远程工作区可以运行：

```bash
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

Android/iOS：先在示例目录生成对应平台壳（iOS 需要 macOS），再选择设备运行：

```bash
flutter create --platforms=android,ios .
flutter run
```

也可以将 **`lib/main.dart` 的完整内容**复制到任意新建的 Flutter 项目，不需要安装第三方包或配置图片资源。目标项目的 `pubspec.yaml` 需保留 `flutter: uses-material-design: true`。

## 布局规格

| 元素 | 实现 |
| --- | --- |
| 背景 | `0xFF121212`，白色主内容，`0xFFAAAAAA` 次级文字 |
| 页面 | `SafeArea`，左右 24dp；宽屏最大宽度 460dp |
| 顶栏 | 48dp；中间音视频胶囊内边距 3dp，选项 56 × 36dp |
| 封面 | 顶栏后 16dp；正方形，16dp 圆角；短屏适当缩小 |
| 歌曲信息 | 封面后 24dp；标题 26sp / w700，歌手 16sp，间距 6dp |
| 功能胶囊 | 信息后 16dp；最小高度 40dp，按钮间距 8dp，半透明白底 |
| 进度 | 胶囊后 12dp；轨道 2dp，滑块半径 3dp，时间 11sp |
| 主控制 | 进度后 8dp；72dp 白色圆形暂停键，黑色 38dp 图标 |
| 底部 | 主控制后至少 16dp；32 × 4dp 把手，下方 12dp 间隔、12sp 来源文字 |

封面按可用宽高调整但始终保持 1:1。短屏、横屏及大字号下可纵向滚动；功能胶囊独立横向滚动。标题过长显示省略号。没有关闭系统字体缩放。

## 交互范围

- 初始显示暂停按钮和 `0:07 / 4:00`。
- 音视频、播放/暂停、随机和循环按钮切换本地 UI 状态。
- 赞/踩互斥且可取消；保存切换本地显示状态。
- 可拖动进度条，时间同步更新；不会自动计时或真实播放。
- 歌词/更多/来源按钮打开说明面板，不伪造歌词或队列数据。
- 上下首显示单曲示例提示；收起在可返回时退出路由，否则提示。
- 分享将歌曲信息复制到剪贴板，不调用系统分享服务。
- 底部把手是面板视觉指示；点击来源可打开面板，未实现拖拽展开。
- 所有状态仅在当前页面存活期间保留，不写入原应用歌单。

使用自定义内容：

```dart
const YoutubeMusicPlayerPage(
  title: '歌曲名称',
  artist: '歌手名称',
  source: '赞过的音乐',
  coverImage: AssetImage('assets/cover.jpg'),
)
```

外部图片需在使用方注册资源；不传 `coverImage` 时直接显示离线占位封面，加载失败也会回退到占位图。

## 检查

在示例目录运行：

```bash
dart format lib test
flutter analyze
flutter test
```

测试覆盖初始 UI、封面比例、播放/暂停、赞踩互斥、拖动进度、音视频与随机/循环状态、功能栏滚动、保存、歌词面板、不同屏幕尺寸与大字号。

**交付时环境未安装 Flutter / Dart SDK，因此上述分析与 Widget 测试尚未执行。**

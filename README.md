# Apple Container

Apple `container` 的图形界面（原生 macOS SwiftUI 应用）。不想敲命令行时，用它管理容器。

## 安装位置

- 应用：`/Applications/Apple Container.app`（已安装，可从启动台/聚焦搜索打开）
- 源码：`~/DeepSeek Harness/apple-container-gui/`

## 功能

| 页面 | 能做什么 |
|---|---|
| **总览** | 服务状态、容器/镜像数量、磁盘占用与可回收空间、CPU 核数、**清理磁盘**（逐项列出真实占用并可勾选清理）、一键清理已停止容器 |
| **容器** | 表格列出全部容器（名称/镜像/状态/端口/IP/CPU/内存），行内启动、停止、看日志、**编辑资源**、删除；右键菜单还有重启、复制容器名 |
| **镜像** | 列出本地镜像（名称/标签/架构/大小/创建时间），拉取镜像（含常用镜像快捷按钮）、删除镜像、用镜像一键起容器 |
| **日志** | 独立窗口展示容器日志，支持自动刷新、自动滚动、行数切换（100/500/1000/全部）、一键复制 |
| **新建容器** | 表单填写镜像、名称、端口映射、目录挂载（可视化选文件夹）、环境变量、CPU/内存、启动命令，**底部实时预览等价命令** |
| **设置** | 自动刷新开关与间隔、是否显示已停止容器、是否显示程序坞图标、系统信息、服务启停 |
| **菜单栏** | 常驻状态栏图标：启停服务、启停每个容器、打开主界面、显示/隐藏程序坞图标、退出 |

## 菜单栏图标

状态栏常驻一个**等距立方体**（与 App 图标中间那个立方体同一套几何，见 `CubeGlyph.swift`）：
服务未运行或没有容器在跑时是线框，有容器在跑时是实心三面，旁边直接标出正在运行的容器数。

点开可做：启停容器服务、启停单个容器、打开主界面、切换程序坞图标、退出。

- 立方体是**模板图**（`isTemplate = true`），菜单栏在深浅色下会自动反色。
- ⚠️ 画这类图标时注意：`NSBitmapImageRep` 的绘图上下文用**点**坐标（`rep.size` 才是点），
  不是像素。拿 `pixelsWide` 去换算会让图形放大一倍并从上方被裁掉（本项目踩过）。
- **关掉主窗口不会退出应用，也不会停掉服务** —— 菜单栏图标和后台服务继续留着（实测：关闭窗口后进程存活、`container system start` 启动的服务在退出 GUI 后依然 `running`）。
- 想彻底退出用菜单里的「退出 Apple Container」或 ⌘Q。
- **显示程序坞图标**（设置页或菜单栏都能切）：关掉后只留菜单栏图标（`NSApplication.ActivationPolicy.accessory`），主窗口照常能开。选择会记住。
- 只剩菜单栏图标时，自动刷新降到 10 秒一次（主窗口开着时按设置页的间隔）。

## 修改已建容器的 CPU / 内存

Apple container **没有**修改已建容器的命令（无 `update`/`edit`/`set`），参数在创建时就固化进容器的 `config.json`。
容器页每行（或右键菜单）的 **「编辑资源」** 可以事后改 CPU 核数与内存：

- 实现方式：停止容器 → 改写 `~/Library/Application Support/com.apple.container/containers/<id>/config.json` 里的
  `resources.cpus` 与 `resources.memoryInBytes` → 重新启动容器。
- **不需要重启整个容器服务**，所以不会影响其他正在运行的容器。运行中的容器会自动停止再拉起。
- 只改这两个字段，端口、挂载、环境变量等一律原样保留。
- 已实测：改完容器内 cgroup 的 `cpu.max` / `memory.max` 立即反映新值。

⚠️ 一个已知的显示特性：`container ls` / `inspect` 读的是 apiserver 的**缓存**，
改完配置后它们会**一直报旧值**，只有重启整个容器服务才会刷新。
因此应用改完会直接把新值写进界面模型，让列表立刻显示正确的数字。

## 清理磁盘

总览页的「磁盘明细」里有 **清理…** 按钮（有可回收空间时会提示「查看哪里能清理…」）。

先说清一个容易误解的地方：**镜像页显示的体积和总览的磁盘占用差一个数量级**，两者都对，只是口径不同。

| 位置 | 统计的是什么 |
|---|---|
| 镜像页 | `variants[].size` —— **压缩后的下载体积** |
| 总览 / `system df` | 磁盘上**解包后的真实占用** |

原因是拉取多平台镜像时，Apple container 会把**所有架构都解包落盘**（拉取日志里能看到
`Unpacking image for platform linux/s390x` 之类）。所以像 `node:12-alpine` 这种 6 平台镜像
会占约 7 GB，而本机其实只用得到 arm64。

清理弹窗会**逐项列出**：名称、说明（几个仓库名 / 几个平台）、磁盘真实占用，
正在被容器使用的标绿「使用中」且不可勾选。默认勾选可清理的镜像项，点清理会先弹确认框。

只做两件事：`container image delete` 删未使用镜像；移除既没有镜像也**没有容器引用**的孤立快照目录。
系统镜像（`vminit`、`container-builder-shim/builder`）虽然不在镜像页显示，但会被识别并保护，不会被误删。

## 使用要点

- **服务默认不运行**：应用启动时不会自动拉起后台服务，也不会把它注册成开机自启。
  需要时点容器/镜像页或总览页的「启动服务」按钮即可，启动后服务会保持运行，直到手动停止或重启电脑。
- 服务未启动时，容器页与镜像页会显示统一的引导界面（而不是空白列表或报错）。
- 容器列表每 3 秒自动刷新（可在设置里调整或关闭），CPU 百分比按两次采样的 CPU 时间增量计算。
- 停止容器服务会中断所有运行中的容器，应用会保留提示。

## 图标

图标由 `make-icon.swift` 现场矢量绘制，两套产物并存：

| 产物 | 用途 |
|---|---|
| `AppIcon.icns` | macOS 15 及更早，通过 `CFBundleIconFile` 读取 |
| `AppIcon.icon/` → `Assets.car` | macOS 26+ 的分层图标，含**浅色/深色/着色**三种外观 |

编译命令（`build.sh` 已内置）：

```bash
xcrun actool AppIcon.icon --compile <out> --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --include-all-app-icons --output-partial-info-plist <out>/partial.plist
```

注意：`icon.json` **只写 `fill-specializations`，不要写顶层 `fill`** —— 两者并存时顶层 `fill`
会盖掉深色特化。另外只有在真的编出 `Assets.car` 时才写 `CFBundleIconName`，
否则旧系统会连 `.icns` 一起放弃，变成白图标。

深色配色不要只是「把浅色调暗」：那样**色相不变**，看起来还是同一个紫色。
苹果深色图标的惯例是**同时大幅退饱和**。本项目实测参考值：

| | RGB | 色相 | 饱和 | 明度 |
|---|---|---|---|---|
| 浅色起点 | 0.38, 0.56, 0.97 | 222° | 61% | 97% |
| 深色起点 | 0.16, 0.18, 0.24 | 225° | **33%** | **24%** |

> ⚠️ 更新已安装的 app 时必须**连 `Contents/Resources/` 一起同步**。
> 只同步 `Contents/MacOS/` 会让新版二进制配旧 `Assets.car`，深色特化就不生效
> （本项目踩过：安装版与构建版的 `Assets.car` 哈希不一致）。

## 重新构建

```bash
cd ~/DeepSeek\ Harness/apple-container-gui
./build.sh
```

构建脚本会自动用 Xcode-beta 的工具链并显式加载 SwiftUI 宏插件
（本机只有 CommandLineTools，其编译器与 SDK 版本不匹配，且
`libSwiftUIMacros.dylib` 位于 Platform 目录而非 toolchain 目录，
不加载会报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`）。

构建完成后如需更新已安装的版本：

```bash
rm -rf "/Applications/Apple Container.app"
cp -R "build/Apple Container.app" /Applications/
```

## 实现说明

- 纯 SwiftUI + AppKit，无第三方依赖，单文件编译（`swiftc`）。
- 所有操作通过调用官方 `container` CLI 完成（绝对路径 `/usr/local/bin/container`，
  因为 GUI 进程的 PATH 通常不含 `/usr/local/bin`），数据靠 CLI 的 `--format json` 解析。
- `container stats` 默认是流式 TUI，这里固定用 `--no-stream --format json` 单次取值。

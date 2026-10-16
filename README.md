# IconKeeper

给 macOS App 换自定义图标，并在 App 自动更新抹掉图标后自动补回来。

*Keep custom macOS app icons alive after apps update themselves. The UI is in Simplified Chinese.*

## 为什么需要它

在「显示简介」里给 App 粘贴图标，实际上是往 App 包的根目录写一个 `Icon\r` 文件，再给包目录的 FinderInfo 打上「有自定义图标」(kHasCustomIcon) 标记。

Chrome 这类会自己更新的 App，升级时会把 `Icon\r` 删掉，标记却留着。系统认为它有自定义图标却找不到文件，程序坞和访达就把它显示成一个蓝色文件夹。

IconKeeper 记下每个 App 该用哪张图标，在后台盯着这些 App，图标一被抹掉就重新设置，并清掉程序坞的图标缓存让它立刻刷新。

## 功能

- **添加**：选一个 App，再选一张图片（icns、png、jpg 等都可以），立即生效
- **拖放**：把 App 拖进窗口就是新增；把图片拖到某一行上就是给那个 App 换图标
- **导入**：扫描 `/Applications` 和 `~/Applications` 里已经换过图标的 App，原样提取 icns 收进列表
- **移除**：可以恢复原图标，也可以保留当前图标、只停止守护
- **后台守护**：LaunchAgent 监视列表里的 App，图标丢失约 20 秒后自动补回（等更新写完再动手）

## 要求

- macOS 14 及以上
- Xcode Command Line Tools（`xcode-select --install`），不需要完整的 Xcode

## 安装

```sh
git clone https://github.com/SnowGlow-aww/IconKeeper.git
cd IconKeeper
./build.sh
```

`build.sh` 会编译、签名，装到 `/Applications/IconKeeper.app`，并写好后台守护。

### 授权「App 管理」

macOS 不允许别的程序随意修改已签名的 App。第一次使用前，到 **系统设置 › 隐私与安全性 › App 管理** 里打开 IconKeeper（列表里没有就点「＋」添加 `/Applications/IconKeeper.app`）。没有权限时，IconKeeper 会弹窗提示并带你去设置。

### 签名与重新编译

`build.sh` 按这个顺序选签名身份：

1. 环境变量 `ICONKEEPER_SIGN_IDENTITY`
2. 钥匙串里第一张 Apple Development 证书
3. 都没有就用临时签名（`-`）

用证书签名，重新编译后「App 管理」权限仍然有效；临时签名每次重新编译后，都要在「App 管理」里把 IconKeeper 删掉再重新添加。

编译产物默认放在仓库里的 `.build/`，可以用 `ICONKEEPER_BUILD_DIR` 改到别处。

## 数据放在哪

| 路径 | 内容 |
| --- | --- |
| `~/Library/Application Support/CustomAppIcons/icons.conf` | 守护列表，每行 `app 路径 = 图标文件` |
| `~/Library/Application Support/CustomAppIcons/icons/` | 图标副本 |
| `~/Library/Application Support/CustomAppIcons/apply-icons.log` | 设置和修复记录 |
| `~/Library/LaunchAgents/com.amia.custom-app-icons.plist` | 后台守护 |

## 命令行

```sh
/Applications/IconKeeper.app/Contents/MacOS/IconKeeper --check          # 检查并修复一次（后台守护跑的就是它）
/Applications/IconKeeper.app/Contents/MacOS/IconKeeper --install-agent  # 按当前列表重写后台守护
```

## 卸载

想把图标换回原样的话，先在窗口里对每个 App 选「恢复原图标并移除」，然后：

```sh
launchctl bootout gui/$(id -u)/com.amia.custom-app-icons
rm ~/Library/LaunchAgents/com.amia.custom-app-icons.plist
rm -rf /Applications/IconKeeper.app ~/Library/Application\ Support/CustomAppIcons
```

## 开发备注

- 只用 Command Line Tools 编译 SwiftUI 时没有 SwiftUI 的宏插件，`@State` 之类的宏编译不过，所以视图状态都放在 `Model`（`ObservableObject`）里。
- App 图标由 `make-icon.swift` 生成。`AppIcon.icns` 已经提交在仓库里，删掉后再跑 `build.sh` 会重新生成。

## 许可

[MIT](LICENSE)

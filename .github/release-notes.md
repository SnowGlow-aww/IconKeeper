## 安装

1. 下载 `IconKeeper.dmg`（或 `IconKeeper.zip`），把 IconKeeper 拖进「应用程序」文件夹，放进去之后再打开。
2. 这个版本没有经过苹果公证，第一次打开会被拦下。到 **系统设置 › 隐私与安全性**，在页面下方点「仍要打开」；或者在终端运行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/IconKeeper.app
   ```
3. 到 **系统设置 › 隐私与安全性 › App 管理** 里打开 IconKeeper。

## 升级

用新版替换「应用程序」里的 IconKeeper 即可。Release 里的版本是临时签名的，**每次升级后都要在「App 管理」里把 IconKeeper 删掉再重新添加**；用自己的 Apple Development 证书从源码编译（`./build.sh`）就没有这个麻烦。

需要 macOS 14 及以上，Apple 芯片和 Intel 都支持。

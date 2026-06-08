# 构建目录(Build Directory)

[English](README.md) | **中文**

该构建目录用于存放应用的全部构建文件与资源。

结构如下:

* bin —— 输出目录
* darwin —— macOS 专用文件
* windows —— Windows 专用文件

## Mac

`darwin` 目录存放 Mac 构建专用的文件。这些文件可被自定义并用于构建。若要恢复为默认状态,直接删除它们再用 `wails build` 构建即可。

该目录包含以下文件:

- `Info.plist` —— Mac 构建用的主 plist 文件,`wails build` 时使用。
- `Info.dev.plist` —— 与主 plist 相同,但用于 `wails dev`。

## Windows

`windows` 目录包含 `wails build` 时使用的 manifest 和 rc 文件。它们可为你的应用自定义。若要恢复默认状态,删除后用 `wails build` 构建即可。

- `icon.ico` —— 应用图标,`wails build` 时使用。若想换图标,直接替换此文件;若缺失,会基于构建目录下的 `appicon.png` 生成新的 `icon.ico`。
- `installer/*` —— 创建 Windows 安装器所用的文件,`wails build` 时使用。
- `info.json` —— Windows 构建用的应用信息。这里的数据会被 Windows 安装器以及应用本身使用(右键 exe → 属性 → 详细信息)。
- `wails.exe.manifest` —— 应用主 manifest 文件。

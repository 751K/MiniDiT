# Premiere Pro 连接

MiniDiT 将导入完成的视频加入 Premiere Pro 当前打开的项目。PR 需要 25.6 或更新版本；使用 Adobe 官方 UXP API。

## 设置

1. 在 MiniDiT 的「设置 › 连接 › Adobe Premiere Pro」点击「安装插件…」。
2. 在 Adobe Creative Cloud 中完成 MiniDiT 插件安装。
3. 在 PR 中选择「窗口 › UXP 插件 › MiniDiT」，打开面板，并打开目标 PR 项目。使用期间保留此面板。
4. 在 MiniDiT 的「设置 › 视频 › 导入至」启用「Adobe Premiere Pro · 当前项目」。

MiniDiT 不修改 PR 的开发者模式或自动化设置。打开插件安装文件仅表示启动安装流程；连接页显示「已连接」和目标项目后，才代表插件可用。未安装 PR 时，连接页显示「未安装」。

## 素材如何进入 PR

原片仍保存在 MiniDiT 的导入位置，PR 引用这些文件，不再复制一份。素材箱结构示例：

```text
11.10-海边
  A001
    C0001.MP4
    C0002.MP4
  B001
    C0001.MP4
```

两个卷中的同名文件按完整文件位置区分。MiniDiT 将已导入的代理关联到原片，不把代理当成额外的原片添加；Shot Mark 转为片段标记。已有不同的用户代理或标记不覆盖，结果中会提示。

原片的嵌入时间码由 PR 自行读取。这一版本不调整 PR 的色彩管理、输入 LUT 或时间码，不建立剪辑序列，不改动用户的时间线；卷号用于素材箱分类，未写入 PR 的 Tape Name 元数据。

## 失败和重试

在「项目 › 导入记录与备份 › 后期软件」中查看 PR 的接收结果。发送失败或部分文件未加入时，可选择「重试发送」，直接使用已保存文件，无需重新连接原卡。

首次发送前记录 PR 项目标识；重试必须回到同一项目。同名的新工程不能替代原工程。首次连接失败、尚未确定目标时，重试会要求确认当前项目。

插件查找整个 PR 项目中的文件，素材被移动到其他素材箱后仍能识别。重试只新增缺失文件；已有片段的代理和标记按原发送计划补处理。原目录未连接、文件大小已变化或可取得的卷标识不匹配时，停止发送并说明原因；这一步不会重新计算整个文件的校验值。

## 验证范围

原生应用编译、核心单元测试、隔离卡实际文件导入/重试、插件生产逻辑的 API 替身检查、本地通信及 CCX 打包检查已通过。当前工作机器未安装 PR，真实插件安装和 PR 软件端导入仍待实测。

## 接口依据

- [Adobe UXP 项目与文件导入接口](https://developer.adobe.com/premiere-pro/uxp/ppro-reference/classes/project)
- [素材箱](https://developer.adobe.com/premiere-pro/uxp/ppro-reference/classes/folderitem)
- [媒体文件与代理关联](https://developer.adobe.com/premiere-pro/uxp/ppro-reference/classes/clipprojectitem)
- [片段标记](https://developer.adobe.com/premiere-pro/uxp/ppro-reference/classes/markers)
- [CCX 打包](https://developer.adobe.com/premiere-pro/uxp/plugins/distribution/package/)

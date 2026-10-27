# FishVoice Solo v5.0 — truly standalone dylib

**独立 dylib**，不加载、链接、嵌入或使用原作者 voicetool.dylib。放进抖音 IPA 时，只注入 FishVoiceSolo.dylib；旧版作者插件和 V1~V4 补丁均不需要注入。

当前已实现：独立全局设置窗口、摇一摇唤起、Fish 官方 API Key Keychain 存储、官方音色搜索 GET /model、收藏及手动添加音色、从官方 POST /v1/tts 合成 MP3、预览、分享音频文件、免费/付费模型选择。系统框架 Foundation UIKit AVFoundation Security，iOS 15+，arm64。

**未完成且不虚报**：
- 不能保证通过抖音私有 IM API 直接发送**原生语音消息**；现阶段为 iOS 系统分享文件的操作，并不等于抖音语音消息。
- 原作者的所有功能（特定直播/评论区语音投递、音频变声、润色、命令模板等）尚未完全独立重写。
- Fish 官方公开音色 ID 可以在官方 API 使用，但作者独占私有模型不能直接复制。
- 仅以静态分析原版 arm64e 的 Objective-C 元数据作为设计依据。没有把作者二进制上传到仓库。

**计费隔离**：本 dylib 的全部内建请求只发送到 api.fish.audio；既不调用作者后台，也不使用作者 Token。注入本 dylib 时不要同时注入原作者插件，否则不能保证其它插件是否仍会请求作者接口。

**安装**：从 Actions「Build FishVoice Solo V5」下载 Artifact，解压得到 FishVoiceSolo.dylib，在全能签里单独注入抖音 IPA，签名安装。首次启动自动展示；之后摇一摇唤起。不往原语音工具自绘设置页插入 UI。

**授权/隐私**：API Key 放在 Keychain，永远不要发布到 GitHub。Fish 接口请求会消耗官方账户额度；付费模型需你自行选择。音色收藏在 NSUserDefaults。

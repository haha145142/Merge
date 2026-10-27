# VoiceTokenPatch V3 — Fish 官方专用版（实验性）

## 设计目标
单独注入此 dylib 和原版 voicetool.dylib。**不要同时注入 V1、V2、V3 补丁**。仅保留 Fish Audio 官方 Token，原插件界面、选择音色与发送流程由 voicetool 自身处理。

- 使用 iOS 15+ 的 UIKit / Foundation / Objective-C / runtime，无 Logos、Substrate、第三方 SDK。
- ZyyFishAudioConfiguration 的实例方法 requestForText:token:voiceID:endpoint:options:error: 被动态接管。
- 此方法一旦被接管，只请求 https://api.fish.audio/v1/tts，不会调用旧实现，不会失败后回退作者合成接口。
- API Key 延续 V2 的 vtpatch.token.fish 本地存储。旧版作者 Token 不再读取、不在设置界面出现。
- 当前选择的原插件 voiceID 被作为 Fish 官方 reference_id；如两边 ID 不一致，可在全局弹窗建立映射。本地映射**不是**把作者私有模型复制到 Fish 官方。
- 首次启动提示、摇一摇唤起全局窗口、音色添加/删除、查看合成状态。
- 不向自定义语音工具页面插入任何控件。

## 不可隐瞒的限制
原插件无源码，已找到同步方法但无法确认其返回值一定是裸音频 NSData；必须实机核验。其他未经过这个方法的合成路径**可能仍走作者服务器**，当前工程不能证明全局拦截完全覆盖。若没找到入口，应停止语音合成测试，不能依靠设置页判断额度。原插件专有的配音、润色、授权或列表获取接口不属于这一 TTS 入口，本补丁不重写它们。

## 编译与测试
工程路径是仓库 VoiceTokenPatch/；GitHub Actions 工作流在仓库根部 .github/workflows/voice-token-patch.yml。GitHub Actions 使用 macOS + Xcode SDK + Theos，生成独立 arm64 dylib 供全能签注入。

仅短文本核实一次，请同时比较 Fish 官方用量和作者后台字符额度变化，测试成功前不得宣称不会扣作者余额。切勿公开上传任何 Token。

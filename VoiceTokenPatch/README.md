# VoiceTokenPatch V4 — Fish 官方独立语音（实验性）

> 仅为个人对自有设备/已安装软件进行兼容性研究。目标是使用自己的 Fish API Key 和可访问的官方音色模型完成语音合成，不向作者认证服务器发送官方 Key。不上传作者的二进制或任何凭证到 GitHub。

## 原始 voicetool 1.2 的静态分析（2026-10-28）
原包为 arm64e Mach-O。Objective-C 方法表显示：

- **ZyyFishAudioConfiguration**：合成入口 `+requestForText:token:voiceID:endpoint:options:error:` 是 **类方法**，不是 V3 误用的实例方法。
- **AllVoiceController**：`-presentAuth:` 负责调用作者的密钥授权界面；另有 `-sourceText`、`-defaultVoice`、`-synthesizeAndSend:voiceID:` 和 `-sendAudioFile:text:`。
- **AllVoiceSendItem**：拥有 `audioPath`、`duration`、`audioText`、`mime` 属性。
- **AllVoiceSender**：`+shared` 返回发送模块；`-send:platform:` 接收语音条目和平台。
- **AllVoiceCatalog**、**AllVoicePicker**：分别负责作者音色目录和选择器。作者私有音色不会因为复制 ID 而拥有 Fish 官方使用权限。

这属于直接解析 Objective-C 方法表的静态证据，并非 Hopper/Ghidra/REA 反编译出的完整伪代码。未公开上传原作者二进制。

## V4 实际处理
1. 双 dylib 独立注入：原 `voicetool.dylib` + **V4** `VoiceTokenPatch.dylib`；不要叠加 V1/V2/V3 补丁。
2. 用正确的 `class_getClassMethod` 接管已识别的同步 Fish 合成入口。
3. 在 `AllVoiceController -presentAuth:` 被调用时，改为打开**本补丁的官方合成界面**，不假冒或提交作者 Token；没有触发该入口的其他作者授权流程不保证被覆盖。
4. 新页面可输入文字、官方音色 ID、自己的 Fish Token，调用官方 `https://api.fish.audio/v1/tts`，格式为 WAV。Token 仅保存在本机 NSUserDefaults。
5. 生成成功后，将 WAV 写入应用临时目录，计算 WAV 长度，关闭补丁遮挡窗口、恢复抖音原窗口，尝试用 `AllVoiceSender -send:platform:` 发送。
6. 若发送模块失败，保留独立的音频分享入口。官方请求失败立即报错，不回退到作者合成 API。
7. 支持摇一摇打开全局设置、手动添加与修改音色 ID 映射，不在原作者自绘的“语音工具”设置页插入任何控件。

## 最重要的边界
- 原插件未经完整动态分析。除了已识别的合成方法和授权弹窗，其余可能直接接入作者 API 的路径未被全部覆盖，**不能保证任何操作都绝不扣除作者额度**。
- 发送模块来自第三方无源码插件，只有方法签名和静态元数据得到验证，**尚未确认能实际发送 WAV 到抖音**；回传 YES 也未必表示真正送达。
- 不是绕过作者服务授权访问作者的付费资源；官方独立音频合成必须使用你自己的 Fish Key。
- 官方私有音色/模型必须拥有 Fish 侧访问权限，作者平台编号不一定等于官方 reference_id。
- 切勿把任何 Token 提交到公开 GitHub。若此前把官方 Key 提交给作者验证器，建议撤销旧 Key。
- 在未核实前先用一次短文字合成，检查 Fish 和作者平台的额度变化；不要反复付费测试。

## 构建
GitHub Actions：`.github/workflows/voice-token-patch.yml`。macOS Xcode SDK + Theos，输出独立 arm64 dylib，无 CydiaSubstrate/ElleKit 依赖。

作者插件 arm64e；本补丁 arm64。iOS 15+ 系统框架 Foundation、UIKit，动态运行时 `libobjc`，无需额外用户安装库。

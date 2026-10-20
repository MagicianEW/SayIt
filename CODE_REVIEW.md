# SayIt（说吧）产品功能代码审查

- 审查基线：`main` @ `d429b7b`（v0.1.4）
- 审查范围：`apps/sayit_app/lib`（1837 行 Dart）、`sayit-poc/crates`（1503 行 Rust）、`scripts` 与 `.github/workflows/build.yml`
- 审查视角：按 README 声明的产品功能逐项对照实现

## 修复状态

本文 14 条已全部处理，另在修复过程中新发现 1 条（原报告漏掉，已单独修复）。

| # | 问题 | 状态 | 落点 |
|---|------|------|------|
| 1 | 帮助对话框说 WAV / 承诺句间停顿 | ✅ 已修 | `main.dart` 帮助文案；并加了一条回归测试钉住 |
| 2 | 每句 3 个 Python 进程 | ✅ 已修 | 新增 `sayit-poc --check-env`，预检移出逐句路径；`cases.rs` 不再逐次预检 |
| 3 | 试听打断合成 + 高亮跳回首句 | ✅ 已修 | `onTap` 加 `_isGenerating` 保护与 `_previewToken`；`_isPreviewing` 让 `positionStream` 跳过高亮 |
| 4 | 停止按钮停不了合成 | ✅ 已修 | `Process.run` → `Process.start` + `_cancelRequested` + `kill()`；停止按钮在忙碌时也可点 |
| 5 | 导出总是整篇重新合成 | ✅ 已修 | `_mixedAudioFor` 按输入指纹缓存 |
| 6 | 扫描"成功但 0 个"被当"全部可用" | ✅ 已修 | 显式区分两种状态，状态栏如实说明 |
| 7 | 基础设置不持久化 | ✅ 已修 | `_loadSettings` / `_schedulePersist`（500ms 防抖） |
| 8 | 导入设定不校验自洽 | ✅ 已修 | 以音色反推语言/性别；不一致时 Snackbar 明说修正了什么 |
| 9 | HsiaoChiehNeural 性别标错 | ✅ 已修 | `voice_data.dart` |
| 10 | `--ssml-base64` 名不副实 | ✅ 已修 | 重命名为 `--text-base64` / `SynthesizeRequest.text`（仅改名，行为不变，已端到端实测） |
| 11 | CI 无质量门禁 | ✅ 已修 | 新增 `test` job（`--check` × 2 / `flutter analyze` / `flutter test` / `cargo test`），并挂为 `release` 的依赖 |
| 12 | `_sentenceIndexAt` 线性扫 | ✅ 已修 | 改二分查找 |
| 13 | "精确不漂移"断言过满 | ✅ 已修 | 代码注释 + README 均改为"近似" |
| 14 | Latin-1 兜底对中文必然错 | ✅ 已修 | 新增依赖 `charset_codec` 做真正的 GB18030 解码（`src/text_decoder.dart` + 10 个单测）；UTF-16 按 BOM 一并识别 |
| ★ | 内置音色表 42/131 已被 Edge 下线，导致 **7/74 个语言×性别组合变空**（阿拉伯语整个语言已死） | ✅ 已修 | 语言/性别下拉按"当前真有可用音色"收敛；失效条目在 `voice_data.dart` 记录了核对方法 |

**验证情况**（已全部实跑）：

- `cargo test` 16 项全过
- `--check-env` 与端到端合成实测通过（`format=mp3`，MP3 帧头 `fff364`）
- `sync_version.py --check` / `sync_app_name.py --check` 通过
- **`flutter test` 23 项全过**（11 个分句单测 + 界面冒烟 + 帮助文案回归 + 10 个编码解码单测）——这条门禁此前从未被真实执行过
- `flutter analyze --no-fatal-warnings --no-fatal-infos` exit 0；有 3 条 warning，全部来自 just_audio 的实验性 API（`_BytesAudioSource` 里的 `StreamAudioSource` / `StreamAudioResponse`，既有代码）。**别改成默认的 fatal-warnings，否则这 3 条会直接卡住发版。**

**新增依赖的代价**：`charset_codec` 0.1.1 自带一个 **6.7MB** 的生成代码文件（`codec_mbcs_data.g.dart`，CPython 的 MBCS 编解码全表）。首次编译明显变慢（实测首次 `flutter test` 两分钟以上，增量缓存后 5 秒）。二进制体积增大幅度**未实测**（需完整 `flutter build`，本次未做）。如果介意，可以改成自实现 GB18030 表（只覆盖常用区，代价是冷僻字会缺）。

**环境坑**：`flutter analyze` 在**路径含非 ASCII 字符**时（如 `~/开发/SayIt`）会让 analysis server 崩溃
（`FormatException: Unexpected end of input`，LSP 的 `Content-Length` 按字符数而非字节数算）。
`flutter test` 不受影响；CI 也不受影响（runner 工作目录是纯 ASCII）。详见 `LOCAL_SETUP.md` §5.3。

---

## 结论先说

代码整体质量高于一般个人项目：分句器、平台落点探测、格式自洽校验都做得扎实，注释普遍保留"以前怎么错的"的决策记录。

问题集中在**一处文档漂移**和**三处会直接影响用户使用的交互缺陷**。此外 CI 完全没有质量门禁——这解释了为什么文档会漂移而无人发现。

功能对照总览：

| 功能 | 实现质量 | 主要问题 |
|------|---------|---------|
| 多语种（37 种） | 好 | 无死组合，已核对 |
| 多音色（131 个） | 中 | 1 条性别标注错误；扫描空结果被误当"全部可用" |
| 参数可调（语速/音高/音量） | 中 | 设置不持久化，重启即丢 |
| 逐句播放与高亮 | 中 | 试听打断合成、高亮跳回首句；停止按钮停不了合成 |
| 导出 MP3 | 中 | 总是整篇重新合成；帮助文案说成 WAV |
| 设定导入导出 | 中 | 不校验音色与语言/性别的一致性 |
| 安装分发与 CI | 弱 | 无测试、无 analyze、`--check` 从未执行 |

---

## P0 · 会直接影响用户使用

### 1. 帮助对话框描述的导出格式和句间停顿，与实际行为完全相反

`apps/sayit_app/lib/main.dart:903,906-909`

界面里唯一的用户帮助写着：

- 「句末标点决定句间停顿：。！？ 500ms，； 300ms，, . ; : 200ms。」
- 「保存为 WAV 文件」
- 「文件名格式：序号_前10个字.wav」
- 「内部使用 24kHz 16bit 单声道 PCM，因此导出为无损 WAV 而不是 MP3。」

实际实现是：

- 导出格式是 MP3：`main.dart:62` `const _kAudioExtension = 'mp3';`，写文件在 `main.dart:620`
- 句间停顿功能已整体删除：`main.dart:68-73` 用 6 行注释说明了原因（edge_tts 固定输出 MP3，插静音需解码重编码，本项目无 MP3 编码器），`text_segmenter.dart:44-49` 也有对应记录

README 第 16 行已经改对了（`支持导出 MP3（24kHz / 48kbps / 单声道）`），只有界面文案没跟上。用户按帮助里的预期使用，会同时在两处产生落差：拿不到 WAV，也听不到那套标点停顿。

修法：把这 4 行改写成 MP3 现状，并删掉停顿表——那句停顿描述现在是无中生有。

### 2. 每合成一句要拉起 3 个 Python 进程，N 句文本 = 3N 次进程启动

链路是这样的：

1. Dart 逐句合成，每句一次 `Process.run`（`main.dart:450-465`，`_mixSentences` 的循环）
2. 每次 `sayit-poc` 启动后，第一件事就是 `check_python_env()`（`sayit-poc-bin/src/cases.rs:298`）
3. `check_python_env` 自己又 `Command::new(python).output()` 跑两次（`sayit-edge/src/lib.rs:233` 查版本、`:250` 查 `import edge_tts`）
4. 之后才是真正合成的那一次 Python

也就是说，**一句文本 = 1 个 sayit-poc + 3 个 Python 进程**，其中两个纯属环境预检。20 句的文本就是 80 次进程启动。

关键点是这两个预检在 `cases.rs:298` 里是**无条件调用**的，而 `sayit-poc` 每次都是全新进程——所以在 Rust 侧加缓存也救不了，必须从调用结构上改。

开销量级：本机实测裸 Python 启动约 21ms/次；`import edge_tts` 通常再增加数百毫秒（此估算无法在本机实测，本机未安装 edge_tts）。即保守估计每句也有 0.5s 以上的纯开销，20 句文本要多等 10s 以上。

产品体感：点一次「生成并播放」要等很久，进度只显示「正在合成第 3/20 句」，用户分不清是在排队还是在卡住。

两种改法：

- 轻量：新增 `--check-env` 子命令，Dart 侧在 `_scanVoices`（`main.dart:292`）阶段就跑一次，环境问题当场暴露；`synthesize_text` 里去掉逐次预检。
- 彻底：让 Dart 一次性把整段文本 + 分句信息传给 `sayit-poc`，Rust 在单进程内循环合成并返回分段字节。顺带还能省掉 base64 编解码的开销。

### 3. 点句子试听会打断正在进行的合成，且高亮立刻跳回第 1 句

`main.dart:1256-1271` 的 `onTap` 直接调 `_synthesizeText` + `setAudioSource` + `play`，有两个独立问题：

**（a）无并发保护。** 这里没有 `_isGenerating` 判断。合成进行到第 5 句时点任意句子，会另起一个 `sayit-poc` 进程并把播放器音源换掉，结果是两段音频叠加进同一个输出，顺序还是乱的。

**（b）高亮跳回首句。** `_sentenceAudioOffsetsMs` 只在 `_generateAndPlay` 里更新（`main.dart:524`），试听换了音源却没换偏移表。`positionStream` 回调（`main.dart:211-217`）持续用**整篇**的偏移去算 `_currentSentenceIndex`，而单句音频从 0ms 开始，`_sentenceIndexAt(0)` 因为 `offsets[0] == 0` 恒返回 0（`main.dart:227-239`）。所以点第 5 句试听，刚设好的高亮会在下一个 tick 就被改回第 1 句。

修法：试听时把 `_sentenceAudioOffsetsMs` 临时换成 `[0]`，或加 `_previewing` 标志让 `positionStream` 跳过高亮更新。

### 4. 「停止」按钮停不了正在进行的合成

`main.dart:1051` 的停止只调 `_audioPlayer.stop()`。而合成循环 `await` 的是 `Process.run`（`main.dart:457`），Dart 侧没有持有进程句柄——唯一的取消手段是 `main.dart:451` 的 `if (!mounted) throw`，也就是**只有关掉窗口才真的能停**。

用户视角：长文本合成到一半按「停止」毫无反应，必须等全部合成完；这期间「生成并播放」还被 `_isGenerating` 禁用（`main.dart:1038`），整个界面像是卡死了。

修法：`Process.run` 换成 `Process.start` 保存 `Process` 句柄，加 `_cancelRequested` 标志并在循环里 `kill()`；停止按钮在 `_isGenerating` 时也保持可用。

---

## P1 · 影响体验与一致性

### 5. 导出总是把整篇重新合成一遍

`_exportAudio`（`main.dart:583`）无条件调 `_mixSentences`，不复用 `_generateAndPlay` 已经拿到的 `_MixedAudio`。用户「先生成并播放，再导出」——同样的文本被完整合成两遍，每遍都是 N 次网络请求加 3N 次进程启动。

修法：缓存一份 `_MixedAudio`，同时记录生成时的 `(文本, 音色, 语速, 音高, 音量)` 指纹，任一项变化才失效。

### 6. 语音扫描「成功但返回空」会被当成「全部音色都可用」

`main.dart:180-189`：

```dart
final available = _voiceScanFailed ? <String>{} : _availableVoices;
return voiceData
    .where((v) => ...)
    .where((v) => available.isEmpty || available.contains(v.value))
```

`available` 为空有**两种**含义：扫描失败（已被 `_voiceScanFailed` 分支处理）和扫描成功但返回 0 条。后者会命中 `available.isEmpty` 退化成「不过滤」，等于扫描白做——界面会把微软可能已下线、或本机环境不存在的音色全列出来，用户选到之后才在合成时失败。

修法：把「扫描成功且为空」单独成一个状态（例如提示「扫描到 0 个可用语音」并给重试入口），不要和「扫描失败」合并成 `available.isEmpty`。

### 7. 基础设置不持久化，重启即丢

只持久化了导出路径 `_kExportPathKey`（`main.dart:43`、写入在 `:772-777` 与 `:832-833`）。音色、语速、音高、音量全部是内存态（`main.dart:172-177`），退出即丢。

项目里已经引入了 `shared_preferences` 且读写范式现成，这四项照抄导出路径的写法即可。当前体验割裂：每次重启都要重设语速和音色，而保存设置只能手动走「导出设定」写文件。

### 8. 导入设定不校验音色与语言/性别的一致性

`_importSettings`（`main.dart:780-793`）把 language、gender、voice 三个字段各自校验后**独立写入**。如果设定文件里 voice 是 zh-CN 的、language 是 ja-JP，导入后：

- 语言下拉显示「日语」
- 音色下拉显示「无可用语音」（`_voiceDropdownValue` 收敛成 null，`main.dart:195-198`）
- 但合成照常进行——`_synthesizeText` 只检查 `voice.isEmpty`（`main.dart:360-362`），会用那个中文音色去读日语文本

界面显示的和实际用的对不上。修法：导入时以 voice 为准反推 language/gender，或检测到不一致时拒绝导入并明确提示。

---

## P2 · 数据、命名与工程质量

### 9. voice_data 有一条性别标注与名称自相矛盾

`apps/sayit_app/lib/src/voice_data.dart:62`：

```dart
VoiceInfo(name: '晓洁(女)-自然流畅', value: 'zh-TW-HsiaoChiehNeural', ... gender: 'male'),
```

名称标「(女)」，性别却是 `male`。筛选按 gender 走，于是用户在「台语 / 女」下永远看不到它，在「台语 / 男」下看到一个写着「(女)」的音色。131 条里就这 1 条。

顺带核对过：37 种语言 × 男女 = 74 个组合**全部有音色**，没有空组合，语言下拉不会给出选完却无法合成的死路。

### 10. `--ssml-base64` 名不副实

Dart 传的是 `preprocessText` 的**纯文本**（`main.dart:364-368`，参数名 `--synthesize-text=` 与 `--ssml-base64`，见 `main.dart:380-385`），Rust 解 base64 后塞进名为 `ssml` 的字段（`cases.rs:304` `ssml: opts.text.clone()`），最后作为 `edge_tts.Communicate` 的第一个位置参数（`sayit-edge/src/lib.rs:580-587`）。

**行为是对的**——edge_tts 会自己转义并套上 SSML 模板，rate/pitch/volume 也由 Communicate 参数注入。但从 `SynthesizeRequest.ssml` → `--ssml-base64` 这条命名链会误导后来人以为可以直接传 SSML 进去，而真传了就会绕过 edge_tts 的转义。建议字段改名为 `text`，开关改为 `--text-base64`。

### 11. CI 没有任何质量门禁

`.github/workflows/build.yml` 的四个 job 全部是「装依赖 → 编译 → 打包 → 上传」，没有 `flutter test`，也没有 `flutter analyze`，更没有 `cargo test`。结果是：

- 仓库里 3 个测试文件**从不执行**：`text_segmenter_test.dart`（11 个用例）、`widget_test.dart`（冒烟）、`sayit-edge` 的 5 个单测
- `cases.rs` 的 case1/3/4 只在 `--case` 手动模式跑，CI 不碰
- README 写着 `sync_version.py --check` / `sync_app_name.py --check` 用于「提交前 / CI 检查」，但 build.yml 只调用了写入模式（`--set`、无参），`--check` **从未被任何地方执行**

后果就是第 1 条那种漂移：分句规则改了、版本号手改了、帮助文案过期了，CI 照样全绿。

本次实测：`cargo test` 6 个用例全过（5 单测 + 1 doctest）。Dart 侧本机没有 flutter/dart 工具链，未能实跑。

### 12. `_sentenceIndexAt` 每次 position tick 做线性扫描

`main.dart:227-239`。`positionStream` 推送频率高，长文档（比如 500 句）就是每个 tick 扫 500 项。改二分查找即可，或记住上次 index 从该处往后找。

### 13. 高亮与进度条用了两套时间基准

- 高亮：`_bytesToMs`（`main.dart:475-477`）按 48kbps CBR 从字节数换算
- 进度条：`_totalDuration` 来自 just_audio 上报的解码时长（`main.dart:218-223`）

拼接的每段 MP3 各自带自己的帧头与编码器延迟信息，两者一旦有偏差，尾部句子的高亮会系统性偏移。`main.dart:64-66` 和 README 第 39 行都断言「精确不漂移」，这个说法给得偏满，建议改成「近似对齐」，并拿一段长文本实测一次偏移量再定论。

### 14. 非 UTF-8 文本的兜底方案对中文用户几乎必然是错的

`main.dart:663-688`：UTF-8 解码失败时弹窗问「要按 Latin-1 强行读取吗？」，对话框自己都写着「中文会显示为乱码」。GBK/GB18030 文件用 Latin-1 读出来必然是乱码，这个选项等于没有。既然已经要打扰用户一次，不如直接提供「以 GB18030 尝试」，或提示用编辑器另存为 UTF-8。

---

## 值得肯定的部分

- **分句器质量高。** `text_segmenter.dart` 按 rune 遍历并同步维护 UTF-16 偏移，规避了 emoji 代理对被切断的 RangeError；专门处理了小数点、千分位、时间冒号、URL 的 `://`、域名与缩写、连续标点。11 个测试用例正好覆盖这些场景，不是凑数。
- **平台落点探测修掉了一类真问题。** `_pocBinaryCandidates`（`main.dart:259-281`）把各平台多个候选路径都列出来。注释里记着 CI 曾把 Windows 二进制拷到 `Release/` 而 Dart 找 `Release/bin/`、Linux 拷到 `bundle/lib/` 而 Dart 找 `bundle/`——两个平台的发布包都是坏的。改成逐个探测是对的。
- **导出编号跨平台正确。** `main.dart:643-647` 的 `_basename` 显式处理 Windows 的 `\` 分隔符，避开了一个「`nextNum` 恒为 1、第二次导出静默覆盖第一次」的真 bug。
- **格式校验是硬校验而非摆设。** `_synthesizeText` 检查 `format != 'mp3'` 会报错并提示「检查 sayit-poc 是否被旧版本覆盖」（`main.dart:422-425`）；Rust 侧 `EdgeConfig` 也明确删掉了那个从没传给 Python 却当成真值上报的「期望格式」字段（`sayit-edge/src/lib.rs:72-84`），不让元数据撒谎。
- **逐句偏移的算法选对了。** `main.dart:460-464` 用「已写入字节数」而不是累加最后一条 boundary 的结束时间，注释里点明了原做法为什么会随句数累积滞后。
- **子进程超时与借用的处理有实战痕迹。** `sayit-edge/src/lib.rs:377-398` 的注释解释了为什么 `child.wait()` 不能单独放进 `join!`（挂死时 timeout 永远没机会触发）以及为什么要先在独立语句里 await 释放借用。这类注释比代码本身更值钱。

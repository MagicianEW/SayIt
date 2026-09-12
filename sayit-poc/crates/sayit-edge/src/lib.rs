#![allow(unexpected_cfgs)]

//! SayIt Edge TTS 客户端（PoC —— PyO3 嵌入式）。
//!
//! ## 设计
//!
//! Rust 端**不**直接发起 WebSocket，而是 spawn `python3` 子进程跑 `edge-tts`。
//! 这样绕开 rustls 的 TLS ClientHello 指纹问题（已实测：rustls 403、Python OpenSSL 200）。
//!
//! ## 协议
//!
//! Python 脚本接收 JSON stdin：`{"text": "...", "voice": "...", ...}`
//! Python 脚本通过 stdout 流式输出两行：
//! - `AUDIO <base64>`：一段 MP3 字节（edge_tts 输出格式固定，见 [`EDGE_OUTPUT_FORMAT`]）
//! - `META <json>`：WordBoundary / SentenceBoundary / Format 事件
//! - `DONE`：结束
//! - `ERROR <msg>`：错误
//!
//! 首条 `META {"type":"Format",...}` 在音频流开始前发送，告知 Rust 层
//! 真实采样率和格式（替代硬编码），使 PCM 和 MP3 两种输出格式均能正确工作。
//!
//! ## v1.4 对齐
//!
//! - v1.4 §3.1.4 输出格式优先级：raw-16khz-pcm → audio-24khz-mp3 兜底
//! - v1.4 §3.3.2 边界事件：WordBoundary `text.Text` 字段
//! - v1.4 §3.4 文本预处理：保留中文标点

use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::oneshot;
use tokio::time::timeout;

#[derive(Debug, Error)]
pub enum EdgeError {
    #[error("找不到 python3：{0}")]
    PythonNotFound(String),

    #[error("启动 Python 子进程失败：{0}")]
    SpawnFailed(#[from] std::io::Error),

    #[error("Python 子进程退出码非零：{0}")]
    NonZeroExit(i32),

    #[error("Python 子进程退出非零（含 stderr）：{0}")]
    NonZeroExitWithMessage(String),

    #[error("Python 子进程写出错：{0}")]
    StdinWrite(String),

    #[error("Python 子进程 stdout 读取错：{0}")]
    StdoutRead(String),

    #[error("Python 输出格式错误：{0}")]
    Protocol(String),

    #[error("Python 报告错误：{0}")]
    Remote(String),
}

/// 单次合成的请求。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SynthesizeRequest {
    pub ssml: String,
    pub config: EdgeConfig,
}

/// Edge TTS 配置（PoC 子集）。
///
/// 注意：**没有** `output_format` 字段。edge_tts 6.x / 7.x 的 `Communicate`
/// 不接受该参数，输出格式恒为 `audio-24khz-48kbitrate-mono-mp3`（见
/// [`EDGE_OUTPUT_FORMAT`]）。以前这里存了一个"期望格式"，既没传给 Python，
/// 又被当成真实格式上报给 Dart，导致元数据撒谎。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EdgeConfig {
    pub voice: String,
    pub pitch: String,
    pub rate: String,
    pub volume: String,
}

impl Default for EdgeConfig {
    fn default() -> Self {
        Self {
            voice: "zh-CN-XiaoxiaoNeural".to_string(),
            pitch: "+0Hz".to_string(),
            rate: "+0%".to_string(),
            volume: "+0%".to_string(),
        }
    }
}

/// edge_tts 唯一支持的输出格式（不可配置）。
pub const EDGE_OUTPUT_FORMAT: &str = "audio-24khz-48kbitrate-mono-mp3";

/// 与 [`EDGE_OUTPUT_FORMAT`] 对应的采样率。
pub const EDGE_SAMPLE_RATE: u32 = 24_000;

/// 与 [`EDGE_OUTPUT_FORMAT`] 对应的码率（bit/s），用于按字节数精确换算音频时长。
pub const EDGE_BITRATE_BPS: u32 = 48_000;

/// 合成超时时间（秒）
const SYNTH_TIMEOUT_SECS: u64 = 60;

/// 语音列表超时时间（秒）
const LIST_VOICES_TIMEOUT_SECS: u64 = 60;

/// 解析可用的 Python 解释器路径。
///
/// 优先级：
/// 1. 环境变量 `SAYIT_PYTHON`（用户显式指定）
/// 2. `~/.sayit-venv` 虚拟环境（Unix: `bin/python3|python`；Windows: `Scripts\python.exe`）
/// 3. PATH 上的 `python3`（Unix）/ `python`（Windows）
///
/// 注意：Windows 默认**没有** `python3.exe`，也**不设** `HOME`（只有 `USERPROFILE`），
/// 因此两者都要兜底，否则 Windows 上永远找不到解释器。
pub fn resolve_python_path() -> String {
    if let Ok(p) = std::env::var("SAYIT_PYTHON") {
        let p = p.trim().to_string();
        if !p.is_empty() {
            return p;
        }
    }

    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_default();

    if !home.is_empty() {
        let venv = std::path::Path::new(&home).join(".sayit-venv");
        let candidates: Vec<std::path::PathBuf> = if cfg!(windows) {
            vec![
                venv.join("Scripts").join("python.exe"),
                venv.join("bin").join("python.exe"),
            ]
        } else {
            vec![venv.join("bin").join("python3"), venv.join("bin").join("python")]
        };
        for c in candidates {
            if c.is_file() {
                return c.to_string_lossy().to_string();
            }
        }
    }

    if cfg!(windows) {
        "python".to_string()
    } else {
        "python3".to_string()
    }
}

/// 一次合成调用的完整返回。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SynthesizeResult {
    pub audio: Vec<u8>,
    pub sample_rate: u32,
    pub channels: u16,
    pub format: String,
    pub boundaries: Vec<Boundary>,
}

/// WordBoundary 事件（与 Python stream() 的 SentenceBoundary / WordBoundary 一致）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Boundary {
    pub text_offset: usize,
    pub text_length: usize,
    pub audio_offset_ms: f64,
    pub duration_ms: f64,
    pub text: String,
    pub boundary_type: String,
}

/// edge_tts 可用语音
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Voice {
    pub name: String,
    pub short_name: String,
    pub gender: String,
    pub locale: String,
}

/// Python 脚本输出元数据格式
#[derive(Debug, Deserialize)]
struct MetaFrame {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    offset: u64,
    #[serde(default)]
    duration: u64,
    #[serde(default)]
    length: Option<usize>,
    /// 首条 META 报告的格式信息（Format 事件）
    sample_rate: Option<u32>,
    format: Option<String>,
}

/// Edge TTS 客户端（PyO3 子进程实现）。
pub struct EdgeClient {
    python_path: String,
}

impl EdgeClient {
    /// 使用 [`resolve_python_path`] 自动探测解释器。
    ///
    /// 以前这里硬编码 `"python3"`，导致 Windows（无 `python3.exe`）与
    /// 使用 `SAYIT_PYTHON` / venv 的场景全部失效。
    pub fn new() -> Self {
        Self {
            python_path: resolve_python_path(),
        }
    }

    pub fn with_python_path(p: impl Into<String>) -> Self {
        Self {
            python_path: p.into(),
        }
    }

    /// 检查 Python 环境是否可用（python3 和 edge_tts 模块）。
    /// 如果不可用，返回包含清晰错误信息的 Err。
    pub fn check_python_env() -> Result<String, String> {
        let python_path = resolve_python_path();

        // 检查 python 是否存在
        let python_check = std::process::Command::new(&python_path)
            .args(["-c", "import sys; print(sys.version_info[0])"])
            .output();

        let python_version = match python_check {
            Ok(output) if output.status.success() => {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            }
            Ok(_) | Err(_) => {
                return Err(format!(
                    "Python '{}' 不可用或执行失败。请安装 Python 3.8+ 并确保在 PATH 中。",
                    python_path
                ));
            }
        };

        // 检查 edge_tts 模块是否安装
        let edge_check = std::process::Command::new(&python_path)
            .args(["-c", "import edge_tts; print('ok')"])
            .output();

        match edge_check {
            Ok(output) if output.status.success() => {
                Ok(format!("Python {}.x, edge_tts 可用", python_version))
            }
            Ok(_) | Err(_) => {
                Err(format!(
                    "Python '{}' 已安装，但 edge_tts 模块未安装。\n\
                    请运行: \"{}\" -m pip install edge_tts\n\
                    或创建虚拟环境:\n\
                    \"{}\" -m venv ~/.sayit-venv && ~/.sayit-venv/bin/pip install edge_tts\n\
                    （Windows: %USERPROFILE%\\.sayit-venv\\Scripts\\pip.exe install edge_tts）",
                    python_path, python_path, python_path
                ))
            }
        }
    }

    /// 发起一次合成请求（子进程 + edge-tts）。
    pub async fn synthesize(
        &self,
        req: SynthesizeRequest,
    ) -> Result<SynthesizeResult, EdgeError> {
        let script = PYTHON_SCRIPT;

        let mut child = Command::new(&self.python_path)
            .arg("-c")
            .arg(script)
            .arg(req.config.voice.clone())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let mut stdin = child.stdin.take().ok_or_else(|| {
            EdgeError::StdinWrite("stdin not available".to_string())
        })?;
        let req_json = serde_json::json!({
            "ssml": req.ssml,
            "voice": req.config.voice,
            "pitch": req.config.pitch,
            "rate": req.config.rate,
            "volume": req.config.volume,
        });
        let payload = format!("{}\n", req_json);
        stdin.write_all(payload.as_bytes()).await
            .map_err(|e| EdgeError::StdinWrite(e.to_string()))?;
        drop(stdin);

        let stdout = child.stdout.take().ok_or_else(|| {
            EdgeError::StdoutRead("stdout not available".to_string())
        })?;
        let stderr = child.stderr.take();
        let mut reader = BufReader::new(stdout).lines();
        let mut audio = Vec::<u8>::new();
        let mut boundaries = Vec::<Boundary>::new();
        let mut first_error: Option<String> = None;
        let (tx, mut rx): (oneshot::Sender<(u32, String)>, oneshot::Receiver<(u32, String)>) = oneshot::channel();

        let read_task = async {
            // opt_tx 允许在循环中 take() sender，send() 后变为 None，之后不再尝试发送
            let mut opt_tx: Option<oneshot::Sender<_>> = Some(tx);
            while let Some(line) = reader.next_line().await
                .map_err(|e| EdgeError::StdoutRead(e.to_string()))?
            {
                if line.starts_with("AUDIO ") {
                    if let Some(b64) = line.strip_prefix("AUDIO ") {
                        use base64::Engine;
                        let bytes = base64::engine::general_purpose::STANDARD
                            .decode(b64.trim())
                            .map_err(|e| EdgeError::Protocol(format!("base64: {e}")))?;
                        audio.extend_from_slice(&bytes);
                    }
                } else if line.starts_with("META ") {
                    if let Some(json) = line.strip_prefix("META ") {
                        let meta: MetaFrame = serde_json::from_str(json)
                            .map_err(|e| EdgeError::Protocol(format!("meta json: {e}")))?;
                        if meta.kind == "Format" {
                            // 首条 Format META 事件：告知 Rust 层真实采样率和格式
                            // take() 后 opt_tx 变为 None，之后循环不再尝试发送
                            if let (Some(sr), Some(fmt)) = (meta.sample_rate, &meta.format) {
                                if let Some(tx) = opt_tx.take() {
                                    let _ = tx.send((sr, fmt.clone()));
                                }
                            }
                        } else if meta.kind == "WordBoundary" || meta.kind == "SentenceBoundary" {
                            // edge-tts 的 offset 是 100ns 单位的**音频**时间轴，不是文本偏移。
                            // audio_offset_ms 用于音频对齐（逐句高亮）。
                            //
                            // text_offset 恒为 0：Edge 的 WordBoundary 事件只给音频偏移，
                            // 不提供在纯文本中的字符下标，这里无法凭空算出。调用方不应依赖它。
                            // text_length 若上游没给，退化为 boundary 文本本身的字符数。
                            boundaries.push(Boundary {
                                text_offset: 0,
                                text_length: meta.length
                                    .unwrap_or_else(|| meta.text.chars().count()),
                                audio_offset_ms: (meta.offset as f64) / 10_000.0,
                                duration_ms: (meta.duration as f64) / 10_000.0,
                                text: meta.text,
                                boundary_type: meta.kind,
                            });
                        }
                    }
                } else if line == "DONE" {
                    break;
                } else if line.starts_with("ERROR ") {
                    first_error = Some(line.trim_start_matches("ERROR ").trim().to_string());
                }
            }
            Ok::<(), EdgeError>(())
        };

        let stderr_drain_task = async {
            if let Some(mut s) = stderr {
                let mut buf = String::new();
                use tokio::io::AsyncReadExt;
                let _ = s.read_to_string(&mut buf).await;
            }
        };

        // 注意：不能把 child.wait() 单独放进 tokio::join! 里再对 read_task 做 timeout。
        // tokio::join! 要等**所有** future 完成，若子进程挂死 child.wait() 永不返回，
        // 那 timeout 根本没机会触发。必须把「读 + 等」整体包进同一个 timeout。
        // 先在一个独立语句里 await 完，让 `child.wait()` / 各读取闭包的可变借用**先释放**，
        // 否则后面的 child.kill() 会与仍在作用域内的借用冲突（E0502）。
        // 注意：tokio::join! 是宏，会**当场** await，本身不是 Future，
        // 不能直接塞给 timeout()，必须包一层 async {}。
        let outcome = timeout(
            Duration::from_secs(SYNTH_TIMEOUT_SECS),
            async { tokio::join!(read_task, stderr_drain_task, child.wait()) },
        )
        .await;

        let (read_result, _, process_status) = match outcome {
            Ok(v) => v,
            Err(_) => {
                let _ = child.kill().await;
                return Err(EdgeError::StdoutRead(format!(
                    "synthesis timed out after {SYNTH_TIMEOUT_SECS}s"
                )));
            }
        };

        read_result?;

        let status = process_status?;
        if !status.success() {
            let combined = if let Some(err) = first_error {
                err
            } else {
                format!("exit={}", status.code().unwrap_or(-1))
            };
            return Err(EdgeError::NonZeroExitWithMessage(combined));
        }

        // 从 Python 的 Format META 事件读取真实采样率和格式
        // 若 Python 未发送（兼容旧版本），降级到默认值
        let (sample_rate, format) = match rx.try_recv() {
            Ok((sr, fmt)) => (sr, fmt),
            Err(_) => (24_000, "mp3".to_string()),
        };

        Ok(SynthesizeResult {
            audio,
            sample_rate,
            channels: 1,
            format,
            boundaries,
        })
    }

    /// 获取 edge_tts 所有可用语音列表。
    pub async fn list_voices(&self) -> Result<Vec<Voice>, EdgeError> {
        let script = PYTHON_LIST_VOICES_SCRIPT;

        let mut child = Command::new(&self.python_path)
            .arg("-c")
            .arg(script)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let stdout = child.stdout.take().ok_or_else(|| {
            EdgeError::StdoutRead("stdout not available".to_string())
        })?;

        let mut reader = BufReader::new(stdout).lines();
        let mut voices = Vec::new();

        let read_task = async {
            while let Some(line) = reader.next_line().await
                .map_err(|e| EdgeError::StdoutRead(e.to_string()))?
            {
                if line.starts_with("VOICE ") {
                    if let Some(json) = line.strip_prefix("VOICE ") {
                        let voice: Voice = serde_json::from_str(json)
                            .map_err(|e| EdgeError::Protocol(format!("voice json: {e}")))?;
                        voices.push(voice);
                    }
                } else if line.starts_with("ERROR ") {
                    let err = line.strip_prefix("ERROR ").unwrap_or(&line);
                    return Err(EdgeError::Remote(err.to_string()));
                }
            }
            Ok::<(), EdgeError>(())
        };

        // 与 synthesize 同理：timeout 必须包住「读 + 等」，否则子进程挂死时永远返回不了。
        // 同样先在一个独立语句 await，避免 Child 的可变借用跨越到 kill() 处。
        let outcome = timeout(
            Duration::from_secs(LIST_VOICES_TIMEOUT_SECS),
            async { tokio::join!(read_task, child.wait()) },
        )
        .await;

        match outcome {
            Ok((read_result, status_result)) => {
                read_result?;
                let status = status_result?;
                if !status.success() {
                    return Err(EdgeError::NonZeroExit(status.code().unwrap_or(-1)));
                }
            }
            Err(_) => {
                let _ = child.kill().await;
                return Err(EdgeError::StdoutRead(format!(
                    "list_voices timed out after {LIST_VOICES_TIMEOUT_SECS}s"
                )));
            }
        }

        Ok(voices)
    }
}

impl Default for EdgeClient {
    fn default() -> Self {
        Self::new()
    }
}

/// 同步封装：内部自建 tokio runtime 并 block_on，方便在非 async 上下文调用。
pub fn synthesize_sync(
    ssml: String,
    voice: String,
    pitch: String,
    rate: String,
    volume: String,
) -> Result<SynthesizeResult, String> {
    let client = EdgeClient::new();
    let req = SynthesizeRequest {
        ssml,
        config: EdgeConfig {
            voice,
            pitch,
            rate,
            volume,
        },
    };

    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(client.synthesize(req))
        .map_err(|e| e.to_string())
}

/// 同步封装：获取可用语音列表。
pub fn list_voices_sync() -> Result<Vec<Voice>, String> {
    let client = EdgeClient::new();
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(client.list_voices())
        .map_err(|e| e.to_string())
}

/// Python 脚本 —— 必须与 Rust 端同步维护。
const PYTHON_SCRIPT: &str = r#"
import sys
import asyncio
import json
import base64
import edge_tts

# edge_tts 的输出格式是**固定的**，不可配置（见 Communicate 注释）。
# 这两个常量必须与 edge_tts 内部写死的 outputFormat 保持一致，
# 否则上报给 Rust/Dart 的采样率就是假的（以前就是这样被骗过去的）。
FIXED_SAMPLE_RATE = 24000
FIXED_FORMAT = "mp3"

async def main():
    voice = sys.argv[1]

    # 立即发送 Format 元数据，Rust 层需此信息来正确解读音频
    format_meta = {
        "type": "Format",
        "sample_rate": FIXED_SAMPLE_RATE,
        "format": FIXED_FORMAT,
    }
    sys.stdout.write("META " + json.dumps(format_meta) + "\n")
    sys.stdout.flush()

    raw = sys.stdin.readline()
    if not raw or not raw.strip():
        print("ERROR empty request on stdin", flush=True)
        sys.exit(1)
    try:
        req = json.loads(raw)
    except Exception as e:
        print(f"ERROR bad request json: {e}", flush=True)
        sys.exit(1)

    ssml_or_text = req.get("ssml", "")
    rate = req.get("rate", "+0%")
    pitch = req.get("pitch", "+0Hz")
    volume = req.get("volume", "+0%")

    try:
        # 重要：edge_tts 6.x / 7.x 的 Communicate **没有** output_format 参数
        # （7.x 在 communicate.py 里把 "outputFormat":"audio-24khz-48kbitrate-mono-mp3"
        #  写死）。传这个关键字会直接 TypeError。输出格式不可配置，只能如实上报。
        comm = edge_tts.Communicate(
            ssml_or_text,
            voice=voice,
            boundary="WordBoundary",
            rate=rate,
            pitch=pitch,
            volume=volume,
        )
    except Exception as e:
        print(f"ERROR init: {e}", flush=True)
        sys.exit(1)

    try:
        async for chunk in comm.stream():
            t = chunk.get("type")
            if t == "audio":
                data = chunk["data"]
                sys.stdout.write("AUDIO " + base64.b64encode(data).decode("ascii") + "\n")
                sys.stdout.flush()
            elif t == "WordBoundary" or t == "SentenceBoundary":
                meta = {
                    "type": t,
                    "text": chunk.get("text", ""),
                    "offset": chunk.get("offset", 0),
                    "duration": chunk.get("duration", 0),
                    "length": chunk.get("length"),
                }
                sys.stdout.write("META " + json.dumps(meta, ensure_ascii=False) + "\n")
                sys.stdout.flush()
    except Exception as e:
        print(f"ERROR stream: {e}", flush=True)
        sys.exit(1)

    print("DONE", flush=True)

asyncio.run(main())
"#;

/// Python 脚本：获取 edge_tts 可用语音列表
const PYTHON_LIST_VOICES_SCRIPT: &str = r#"
import sys
import asyncio
import json
import edge_tts

async def main():
    try:
        voices = await edge_tts.list_voices()
        for voice in voices:
            v = {
                "name": voice["Name"],
                "short_name": voice.get("ShortName", ""),
                "gender": voice.get("Gender", ""),
                "locale": voice.get("Locale", ""),
            }
            sys.stdout.write("VOICE " + json.dumps(v, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    except Exception as e:
        print(f"ERROR {e}", flush=True)
        sys.exit(1)

asyncio.run(main())
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_python_path() {
        // 不比对具体值（可能命中 SAYIT_PYTHON 或 ~/.sayit-venv），
        // 只保证一定解析出一个 python 解释器而不是硬编码失败。
        let c = EdgeClient::new();
        assert!(!c.python_path.trim().is_empty());
        assert!(c.python_path.to_lowercase().contains("python"));
    }

    #[test]
    fn resolve_python_path_is_never_empty() {
        let p = resolve_python_path();
        assert!(!p.trim().is_empty());
    }

    #[test]
    fn custom_python_path() {
        let c = EdgeClient::with_python_path("/usr/local/bin/python3");
        assert_eq!(c.python_path, "/usr/local/bin/python3");
    }

    #[test]
    fn output_format_constants() {
        // 必须与 edge_tts 内部写死的值一致，否则上报给上层的采样率是假的
        assert_eq!(EDGE_OUTPUT_FORMAT, "audio-24khz-48kbitrate-mono-mp3");
        assert_eq!(EDGE_SAMPLE_RATE, 24_000);
        assert_eq!(EDGE_BITRATE_BPS, 48_000);
    }

    #[test]
    fn config_default() {
        let c = EdgeConfig::default();
        assert_eq!(c.voice, "zh-CN-XiaoxiaoNeural");
        assert_eq!(c.pitch, "+0Hz");
        assert_eq!(c.rate, "+0%");
        assert_eq!(c.volume, "+0%");
    }
}


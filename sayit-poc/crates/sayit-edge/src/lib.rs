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
//! Python 脚本接收 JSON stdin：`{"text": "...", "voice": "...", "output_format": "..."}`
//! Python 脚本通过 stdout 流式输出两行：
//! - `AUDIO <base64>`：一段 PCM/MP3 字节
//! - `META <json>`：WordBoundary / SentenceBoundary 事件
//! - `DONE`：结束
//! - `ERROR <msg>`：错误
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
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EdgeConfig {
    pub voice: String,
    pub output_format: String,
    pub pitch: String,
    pub rate: String,
    pub volume: String,
}

impl Default for EdgeConfig {
    fn default() -> Self {
        Self {
            voice: "zh-CN-XiaoxiaoNeural".to_string(),
            output_format: "raw-16khz-16bit-mono-pcm".to_string(),
            pitch: "+0Hz".to_string(),
            rate: "+0%".to_string(),
            volume: "+0%".to_string(),
        }
    }
}

/// 输出格式常量
pub const OUTPUT_FORMAT_PCM_16K: &str = "raw-16khz-16bit-mono-pcm";
pub const OUTPUT_FORMAT_MP3_24K_48K: &str = "audio-24khz-48kbitrate-mono-mp3";

/// 合成超时时间（秒）
const SYNTH_TIMEOUT_SECS: u64 = 60;

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
    text: String,
    offset: u64,
    duration: u64,
    length: Option<usize>,
}

/// Edge TTS 客户端（PyO3 子进程实现）。
pub struct EdgeClient {
    python_path: String,
}

impl EdgeClient {
    pub fn new() -> Self {
        Self {
            python_path: "python3".to_string(),
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
        let python_path = std::env::var("SAYIT_PYTHON")
            .unwrap_or_else(|_| {
                let home = std::env::var("HOME").unwrap_or_default();
                let venv_py = format!("{home}/.sayit-venv/bin/python3");
                if std::path::Path::new(&venv_py).exists() {
                    venv_py
                } else {
                    "python3".to_string()
                }
            });

        // 检查 python3 是否存在
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
                    请运行: pip install edge_tts\n\
                    或创建虚拟环境:\n\
                    python3 -m venv ~/.sayit-venv && ~/.sayit-venv/bin/pip install edge_tts",
                    python_path
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
            .arg(req.config.output_format.clone())
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

        let read_task = async {
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
                        if meta.kind == "WordBoundary" || meta.kind == "SentenceBoundary" {
                            boundaries.push(Boundary {
                                text_offset: 0,
                                text_length: meta.length.unwrap_or(0),
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

        let (read_result, _, process_status) = tokio::join!(
            timeout(Duration::from_secs(SYNTH_TIMEOUT_SECS), read_task),
            stderr_drain_task,
            child.wait()
        );

        let read_ok = read_result.is_ok();
        if !read_ok {
            let _ = child.kill().await;
            return Err(EdgeError::StdoutRead("synthesis timed out".to_string()));
        }

        read_result.map_err(|_| EdgeError::StdoutRead("synthesis timed out".to_string()))??;

        let status = process_status?;
        if !status.success() {
            let combined = if let Some(err) = first_error {
                err
            } else {
                format!("exit={}", status.code().unwrap_or(-1))
            };
            return Err(EdgeError::NonZeroExitWithMessage(combined));
        }

        // edge_tts 7.x 的 Communicate.stream() 只返回 MP3 (audio/mpeg, 24kHz)
        // output_format 参数在 Python 端被忽略，保留用于将来 PCM 支持
        let sample_rate = 24_000;
        let format = "mp3";

        Ok(SynthesizeResult {
            audio,
            sample_rate,
            channels: 1,
            format: format.to_string(),
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

        let status = child.wait().await?;
        if !status.success() {
            return Err(EdgeError::NonZeroExit(status.code().unwrap_or(-1)));
        }

        Ok(voices)
    }
}

impl Default for EdgeClient {
    fn default() -> Self {
        Self::new()
    }
}

/// 同步封装：供 flutter_rust_bridge 调用。
///
/// Flutter/Dart 端无法直接调用 async 函数，这里用 tokio::runtime::Runtime::block_on 适配。
#[flutter_rust_bridge::frb(sync)]
pub fn synthesize_sync(
    ssml: String,
    voice: String,
    output_format: String,
    pitch: String,
    rate: String,
    volume: String,
) -> Result<SynthesizeResult, String> {
    let client = EdgeClient::new();
    let req = SynthesizeRequest {
        ssml,
        config: EdgeConfig {
            voice,
            output_format,
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
#[flutter_rust_bridge::frb(sync)]
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
import re
import edge_tts

def strip_ssml(ssml: str) -> str:
    text = re.sub(r"<[^>]+>", "", ssml)
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    text = text.replace("&quot;", '"').replace("&apos;", "'")
    return text.strip()

async def main():
    voice = sys.argv[1]
    output_format = sys.argv[2]
    raw = sys.stdin.readline()
    req = json.loads(raw)
    ssml_or_text = req["ssml"]
    rate = req.get("rate", "+0%")
    pitch = req.get("pitch", "+0Hz")
    volume = req.get("volume", "+0%")

    try:
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
        let c = EdgeClient::new();
        assert_eq!(c.python_path, "python3");
    }

    #[test]
    fn custom_python_path() {
        let c = EdgeClient::with_python_path("/usr/local/bin/python3");
        assert_eq!(c.python_path, "/usr/local/bin/python3");
    }

    #[test]
    fn output_format_constants() {
        assert_eq!(OUTPUT_FORMAT_PCM_16K, "raw-16khz-16bit-mono-pcm");
        assert_eq!(OUTPUT_FORMAT_MP3_24K_48K, "audio-24khz-48kbitrate-mono-mp3");
    }

    #[test]
    fn config_default() {
        let c = EdgeConfig::default();
        assert_eq!(c.voice, "zh-CN-XiaoxiaoNeural");
        assert!(!c.output_format.is_empty());
    }
}


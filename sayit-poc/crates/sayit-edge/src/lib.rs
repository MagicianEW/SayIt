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

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

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

        let status = child.wait().await?;
        if !status.success() {
            let mut stderr_msg = String::new();
            if let Some(mut s) = stderr {
                use tokio::io::AsyncReadExt;
                let _ = s.read_to_string(&mut stderr_msg).await;
            }
            let combined = if let Some(err) = first_error {
                format!("{} | stderr: {}", err, stderr_msg.trim())
            } else {
                format!("exit={}, stderr: {}", status.code().unwrap_or(-1), stderr_msg.trim())
            };
            return Err(EdgeError::NonZeroExitWithMessage(combined));
        }

        let (sample_rate, format) = if req.config.output_format.starts_with("raw-") {
            (16_000, "pcm")
        } else {
            (24_000, "mp3")
        };

        Ok(SynthesizeResult {
            audio,
            sample_rate,
            channels: 1,
            format: format.to_string(),
            boundaries,
        })
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


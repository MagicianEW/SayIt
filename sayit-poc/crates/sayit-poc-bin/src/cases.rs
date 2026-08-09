//! PoC 用例实现。每个函数返回 `(passed, summary, report_path)`。

use std::path::Path;

use anyhow::Result;
use sayit_edge::{EdgeConfig, SynthesizeRequest};

/// 用例 1：PCM 直出测试。
///
/// 流程：
/// 1. 先尝试 `raw-16khz-16bit-mono-pcm`（v1.4 §3.1.4 优先档）
/// 2. 若服务端拒绝（403），降级到 `audio-24khz-48kbitrate-mono-mp3`（上游默认）
/// 3. 验证返回 sample_rate/channels/format/audio 非空
///
/// 失败处理：网络不可用时返回 `(false, "...")` 而非 panic；这允许离线 / CI 环境跑通占位。
pub async fn case1_pcm(reports_dir: &Path) -> Result<(bool, String, String)> {
    // 使用 venv 内的 python3（PoC 约定路径）；fallback 到系统 python3
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
    let client = sayit_edge::EdgeClient::with_python_path(python_path);

    // 优先 raw PCM（v1.4 §3.1.4）
    let primary = SynthesizeRequest {
        ssml: r#"<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN"><voice name="zh-CN-XiaoxiaoNeural">测试文本</voice></speak>"#.to_string(),
        config: EdgeConfig {
            output_format: sayit_edge::OUTPUT_FORMAT_PCM_16K.to_string(),
            ..Default::default()
        },
    };
    let (primary_result, primary_err) = match client.synthesize(primary).await {
        Ok(r) => (Some(r), None),
        Err(e) => (None, Some(format!("{e}"))),
    };

    // 兜底：MP3
    let fallback = SynthesizeRequest {
        ssml: r#"<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN"><voice name="zh-CN-XiaoxiaoNeural">测试文本</voice></speak>"#.to_string(),
        config: EdgeConfig {
            output_format: sayit_edge::OUTPUT_FORMAT_MP3_24K_48K.to_string(),
            ..Default::default()
        },
    };
    let (fallback_result, fallback_err) = match client.synthesize(fallback).await {
        Ok(r) => (Some(r), None),
        Err(e) => (None, Some(format!("{e}"))),
    };

    // 优先采用 primary，否则用 fallback
    let chosen = primary_result.or(fallback_result);

    let (passed, summary, payload) = match chosen {
        Some(result) => {
            let pcm_ok = result.sample_rate > 0
                && result.channels == 1
                && !result.audio.is_empty()
                && (result.format == "pcm" || result.format == "mp3");
            let summary = format!(
                "{} 直出成功：{} 字节 @ {}Hz/{}ch ({} 个 WordBoundary)",
                result.format.to_uppercase(),
                result.audio.len(),
                result.sample_rate,
                result.channels,
                result.boundaries.len()
            );
            (pcm_ok, summary, Some(result))
        }
        None => {
            let summary = format!(
                "未跑通：primary={}；fallback={}",
                primary_err.as_deref().unwrap_or_default(),
                fallback_err.as_deref().unwrap_or_default()
            );
            (false, summary, None)
        }
    };

    let payload_json = match &payload {
        Some(r) => serde_json::json!({
            "audio_bytes": r.audio.len(),
            "sample_rate": r.sample_rate,
            "channels": r.channels,
            "format": r.format,
            "boundaries_count": r.boundaries.len(),
            "first_boundary": r.boundaries.first(),
            "primary_attempt": if primary_err.is_none() { "ok" } else { "failed" },
            "primary_error": primary_err,
            "fallback_attempt": if fallback_err.is_none() { "ok" } else { "failed" },
            "fallback_error": fallback_err,
        }),
        None => serde_json::json!({
            "status": "skipped",
            "primary_error": primary_err,
            "fallback_error": fallback_err,
        }),
    };

    let path = reports_dir.join("case1_pcm.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&payload_json)?)?;

    Ok((passed, summary, path.display().to_string()))
}

/// 用例 3：DRM Token 生成测试。
///
/// 不实际发起 WebSocket 请求（避免污染 PoC 网络结果），只验证 token 形状。
pub async fn case3_drm(reports_dir: &Path) -> Result<(bool, String, String)> {
    let t_now: String = sayit_drm::generate_sec_ms_gec();
    let t_60s_later: String = sayit_drm::generate_sec_ms_gec();

    // 形状断言：64 字符 hex（SHA256 hex），全大写
    let printable = t_now.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase());
    let len_ok = t_now.len() == 64;

    // 时钟 skew 测试
    let t_before = sayit_drm::generate_sec_ms_gec();
    sayit_drm::adj_clock_skew_seconds(3600.0); // +1 小时
    let t_after_skew = sayit_drm::generate_sec_ms_gec();
    sayit_drm::adj_clock_skew_seconds(-3600.0); // 撤销

    let record = serde_json::json!({
        "token_now_len": t_now.len(),
        "token_now_preview": &t_now[..t_now.len().min(40)],
        "token_now_is_printable": printable,
        "token_len_ok": len_ok,
        "token_stable_within_window": t_now == t_60s_later,
        "skew_changes_token": t_before != t_after_skew,
        "muid_sample": sayit_drm::generate_muid(),
    });

    let passed = printable && len_ok && t_now == t_60s_later && t_before != t_after_skew;
    let summary = format!(
        "DRM token 长度={}，可打印={}，同窗口不变={}，skew 影响 token={}",
        t_now.len(),
        printable,
        t_now == t_60s_later,
        t_before != t_after_skew
    );

    let path = reports_dir.join("case3_drm.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&record)?)?;
    Ok((passed, summary, path.display().to_string()))
}

/// 用例 4：SSML 边界偏移语义测试。
///
/// 流程：
/// 1. 构造 SSML：`<speak>...<voice>第一句。<break time="300ms"/>第二句。</voice></speak>`
/// 2. 同时构造纯文本视图：`第一句。第二句。`
/// 3. 调用 Edge TTS，记录每个 WordBoundary
/// 4. 决策：boundary 是否携带 text.Text（v1.4 §3.3.2 关键决策点）
/// 5. 写入 `case4_boundary_offset.json` 与 `boundary_offset_semantics.md`
pub async fn case4_boundary_offset(reports_dir: &Path) -> Result<(bool, String, String)> {
    let ssml = r#"<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN"><voice name="zh-CN-XiaoxiaoNeural">第一句。<break time="300ms"/>第二句。</voice></speak>"#;
    let plain_text = "第一句。第二句。";

    // 使用 venv 内的 python3（用户本地约定路径）；fallback 到系统 python3
    let python_path = std::env::var("SAYIT_PYTHON")
        .unwrap_or_else(|_| {
            // 优先 ~/.sayit-venv/bin/python3（v1.4 PoC 约定）
            let home = std::env::var("HOME").unwrap_or_default();
            let venv_py = format!("{home}/.sayit-venv/bin/python3");
            if std::path::Path::new(&venv_py).exists() {
                venv_py
            } else {
                "python3".to_string()
            }
        });
    let client = sayit_edge::EdgeClient::with_python_path(python_path);
    let req = sayit_edge::SynthesizeRequest {
        ssml: ssml.to_string(),
        config: sayit_edge::EdgeConfig::default(),
    };

    let result = match client.synthesize(req).await {
        Ok(r) => r,
        Err(e) => {
            let record = serde_json::json!({
                "status": "skipped",
                "reason": format!("未跑通：{}", e),
                "ssml": ssml,
                "plain_text": plain_text,
                "expected_decision": "阶段 2 前必须用联网环境补跑"
            });
            let path = reports_dir.join("case4_boundary_offset.json");
            std::fs::write(&path, serde_json::to_vec_pretty(&record)?)?;

            let md_path = reports_dir.join("boundary_offset_semantics.md");
            std::fs::write(
                &md_path,
                format!(
                    "# SSML 边界偏移语义（未跑通）\n\n本次 PoC 因网络原因未跑通用例 4。\n\n错误：\n\n```\n{}\n```\n\n请在能访问 `wss://speech.platform.bing.com` 的环境中重新跑：\n\n```bash\ncd sayit-poc && cargo run -p sayit-poc-bin -- --case 4\n```\n",
                    e
                ),
            )?;

            return Ok((false, format!("未跑通：{}", e), path.display().to_string()));
        }
    };

    // 决策：每个 boundary 是否带 text 字符串（v1.4 §3.3.2 关键）
    let mut probes: Vec<serde_json::Value> = Vec::new();
    let mut hits_text = 0;
    let mut hits_ssml = 0;

    for b in &result.boundaries {
        // 检查 text 是否在纯文本视图里
        let in_plain = plain_text.contains(&b.text);
        let in_ssml = ssml.contains(&b.text);
        if in_plain {
            hits_text += 1;
        }
        if in_ssml {
            hits_ssml += 1;
        }
        probes.push(serde_json::json!({
            "text_offset": b.text_offset,
            "text_length": b.text_length,
            "text": b.text,
            "in_plain_text": in_plain,
            "in_ssml_text": in_ssml,
            "audio_offset_ms": b.audio_offset_ms,
            "duration_ms": b.duration_ms,
        }));
    }

    let total = result.boundaries.len();
    let plain_only = hits_text > 0 && hits_ssml == 0;
    let ssml_only = hits_ssml > 0 && hits_text == 0;
    let both = hits_text > 0 && hits_ssml > 0;

    let decision = if total == 0 {
        "no_boundaries"
    } else if plain_only {
        "plain_text"
    } else if ssml_only {
        "ssml_text"
    } else if both {
        "ambiguous"
    } else {
        "no_text"
    };

    let record = serde_json::json!({
        "ssml": ssml,
        "plain_text": plain_text,
        "boundaries_count": total,
        "hits_plain_text": hits_text,
        "hits_ssml_text": hits_ssml,
        "decision": decision,
        "probes": probes,
        "note": "v1.4 §3.3.2 关键决策；阶段 2 据此选映射策略"
    });

    let path = reports_dir.join("case4_boundary_offset.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&record)?)?;

    let md = format!(
        "# SSML 边界偏移语义（用例 4）\n\n## 输入\n\n```xml\n{ssml}\n```\n\n纯文本视图：`{plain}`\n\n## 测量\n\n- 共收到 {total} 个 WordBoundary\n- boundary.text 命中**纯文本视图**：{hits_text}\n- boundary.text 命中**SSML 原文**：{hits_ssml}\n\n## 决策\n\n**`{decision}`**\n\n- `plain_text`：text.Text 在纯文本视图 → 阶段 2 直接按纯文本偏移映射（v1.4 §3.3.2 路径 A）\n- `ssml_text`：text.Text 在 SSML 原文 → 阶段 2 维护\"SSML 偏移 → 纯文本偏移\"转换表（v1.4 §3.3.2 路径 B）\n- `ambiguous`：两边都命中 → 需要进一步细分 PoC\n- `no_boundaries`：服务端没发 boundary → 阶段 2 直接用比例估算兜底（v1.4 §3.3.2 fallback）\n- `no_text`：服务端发了 boundary 但没 text.Text → 阶段 2 走音频时长比例估算\n",
        ssml = ssml,
        plain = plain_text,
        total = total,
        hits_text = hits_text,
        hits_ssml = hits_ssml,
        decision = decision,
    );
    let md_path = reports_dir.join("boundary_offset_semantics.md");
    std::fs::write(&md_path, md)?;

    let summary = format!(
        "边界偏移决策={}（共 {} 个 boundary，命中纯文本 {}，命中 SSML {}）",
        decision, total, hits_text, hits_ssml
    );
    Ok((total > 0, summary, path.display().to_string()))
}

use base64::Engine;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct SynthOpts {
    pub text: String,
    pub voice: String,
    pub output_format: String,
    pub rate: String,
    pub pitch: String,
    pub volume: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SynthesisOutput {
    pub audio_base64: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub format: String,
    pub boundaries: Vec<BoundaryOutput>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct BoundaryOutput {
    pub text_offset: usize,
    pub text_length: usize,
    pub audio_offset_ms: f64,
    pub duration_ms: f64,
    pub text: String,
    pub boundary_type: String,
}

pub async fn synthesize_text(opts: SynthOpts) -> anyhow::Result<SynthesisOutput> {
    // 预检 Python 环境
    if let Err(e) = sayit_edge::EdgeClient::check_python_env() {
        anyhow::bail!("Python 环境检查失败: {}", e);
    }

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

    let client = sayit_edge::EdgeClient::with_python_path(python_path);
    let req = sayit_edge::SynthesizeRequest {
        ssml: opts.text.clone(),
        config: sayit_edge::EdgeConfig {
            voice: opts.voice.clone(),
            output_format: opts.output_format.clone(),
            rate: opts.rate.clone(),
            pitch: opts.pitch.clone(),
            volume: opts.volume.clone(),
            ..Default::default()
        },
    };

    let result = client.synthesize(req).await?;

    let boundaries = result
        .boundaries
        .into_iter()
        .map(|b| BoundaryOutput {
            text_offset: b.text_offset,
            text_length: b.text_length,
            audio_offset_ms: b.audio_offset_ms,
            duration_ms: b.duration_ms,
            text: b.text,
            boundary_type: b.boundary_type,
        })
        .collect();

    let audio_base64 = base64::engine::general_purpose::STANDARD.encode(&result.audio);

    Ok(SynthesisOutput {
        audio_base64,
        sample_rate: result.sample_rate,
        channels: result.channels,
        format: result.format,
        boundaries,
    })
}

/// 获取 edge_tts 所有可用语音列表。
pub async fn list_voices() -> anyhow::Result<Vec<sayit_edge::Voice>> {
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

    let client = sayit_edge::EdgeClient::with_python_path(python_path);
    let voices = client.list_voices().await?;
    Ok(voices)
}
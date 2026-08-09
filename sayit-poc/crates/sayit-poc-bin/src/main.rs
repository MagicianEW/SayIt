//! SayIt PoC 验证入口（阶段 1a）。
//!
//! 对应 v1.4 §9.3 的用例 1 / 3 / 4：
//! - `--case 1`：PCM 直出测试（路径 A）
//! - `--case 3`：DRM Token 生成测试
//! - `--case 4`：SSML 边界偏移语义测试（关键）
//! - `--synthesize-text`：TTS 合成（供 Flutter 调用）
//!
//! 用例 2（MP3 + symphonia 解码）按 v1.4 §9.2 决策留到阶段 1b。

use std::path::PathBuf;

use anyhow::Context;
use clap::{Parser, ValueEnum};
use serde::Serialize;

mod cases;

#[derive(Parser, Debug)]
#[command(name = "sayit-poc", version, about = "SayIt Stage 1a PoC harness")]
struct Cli {
    /// 要跑的用例
    #[arg(long, value_enum)]
    case: Option<Case>,

    /// TTS 合成模式
    #[arg(long, value_name = "TEXT")]
    synthesize_text: Option<String>,

    /// 语音（默认 zh-CN-XiaoxiaoNeural）
    #[arg(long, default_value = "zh-CN-XiaoxiaoNeural")]
    voice: String,

    /// 输出格式（raw-16khz-16bit-mono-pcm 或 audio-24khz-48kbitrate-mono-mp3）
    #[arg(long, default_value = "raw-16khz-16bit-mono-pcm")]
    output_format: String,

    /// 语速（默认 +0%，范围 -100% 到 +100%，负数为减速，正数为加速）
    #[arg(long, default_value = "+0%")]
    rate: String,

    /// 音高（默认 +0Hz）
    #[arg(long, default_value = "+0Hz")]
    pitch: String,

    /// 音量（默认 +0%）
    #[arg(long, default_value = "+0%")]
    volume: String,

    /// 报告输出目录
    #[arg(long, default_value = "reports")]
    reports_dir: PathBuf,

    /// 调试日志
    #[arg(long, default_value_t = false)]
    verbose: bool,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
enum Case {
    /// PCM 直出测试（路径 A）
    #[clap(name = "1")]
    Pcm,
    /// DRM Token 生成测试
    #[clap(name = "3")]
    Drm,
    /// SSML 边界偏移语义
    #[clap(name = "4")]
    Boundary,
    /// 全部
    #[clap(name = "all")]
    All,
}

#[derive(Serialize)]
struct RunRecord {
    case: String,
    passed: bool,
    summary: String,
    report_path: String,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    env_logger::Builder::from_default_env()
        .filter_level(if cli.verbose { log::LevelFilter::Debug } else { log::LevelFilter::Info })
        .init();

    // 合成模式：直接输出 JSON 到 stdout
    if let Some(text) = cli.synthesize_text {
        let opts = cases::SynthOpts {
            text,
            voice: cli.voice,
            output_format: cli.output_format,
            rate: cli.rate,
            pitch: cli.pitch,
            volume: cli.volume,
        };
        let result = cases::synthesize_text(opts).await?;
        println!("{}", serde_json::to_string(&result)?);
        return Ok(());
    }

    // 用例模式
    let case_val = cli.case.expect("either --case or --synthesize-text is required");

    std::fs::create_dir_all(&cli.reports_dir)
        .with_context(|| format!("创建 reports 目录失败: {}", cli.reports_dir.display()))?;

    let cases_to_run: Vec<Case> = match case_val {
        Case::All => vec![Case::Pcm, Case::Drm, Case::Boundary],
        c => vec![c],
    };

    let mut records: Vec<RunRecord> = Vec::new();

    for case in cases_to_run {
        let (passed, summary, report_path) = match case {
            Case::Pcm => cases::case1_pcm(&cli.reports_dir).await?,
            Case::Drm => cases::case3_drm(&cli.reports_dir).await?,
            Case::Boundary => cases::case4_boundary_offset(&cli.reports_dir).await?,
            Case::All => unreachable!(),
        };
        records.push(RunRecord {
            case: format!("{:?}", case),
            passed,
            summary: summary.clone(),
            report_path: report_path.clone(),
        });
        println!(
            "[{}] {:?}: {} → {}",
            if passed { "PASS" } else { "FAIL" },
            case,
            summary,
            report_path
        );
    }

    // 写汇总
    let summary_path = cli.reports_dir.join("summary.json");
    std::fs::write(&summary_path, serde_json::to_vec_pretty(&records)?)?;
    println!("汇总已写入: {}", summary_path.display());

    // 任意失败 → exit code 1
    if records.iter().any(|r| !r.passed) {
        std::process::exit(1);
    }
    Ok(())
}

//! SayIt Edge TTS DRM（Sec-MS-GEC）Token 生成器。
//!
//! 这是 `rany2/edge-tts` 中 `drm.py` 的 Rust 重实现。
//!
//! ## 算法（v1.4 §9.4 维护 Checklist — 当前主分支）
//!
//! 1. `ticks = unix_timestamp + clock_skew_seconds`（clock skew 由服务端 Date 校准）
//! 2. 切到 Windows file time 起点（`WIN_EPOCH = 11644473600`，即 1601-01-01）
//! 3. 向下取整到 5 分钟（`ticks -= ticks % 300`）
//! 4. 转 100ns 间隔：`ticks *= 1e9 / 100 = 1e7`
//! 5. `sha256(format!("{:.0f}{TRUSTED_CLIENT_TOKEN}").as_bytes()).hex().to_uppercase()`
//!
//! ## 与上游的差异
//!
//! - clock skew 校准需要先发一次"试探请求"读 `Date` header——这里只暴露 `adj_clock_skew` 接口
//! - MUID（MUID cookie）独立生成，调用方按需组合
//!
//! ## 参考
//!
//! - 上游 Python 实现：<https://github.com/rany2/edge-tts/blob/master/src/edge_tts/drm.py>
//! - 算法变更讨论：<https://github.com/rany2/edge-tts/issues/290#issuecomment-2464956570>

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use thiserror::Error;

/// Windows file time 起点：1601-01-01 00:00:00 UTC 与 Unix epoch 的秒数差。
const WIN_EPOCH_SECONDS: u64 = 11_644_473_600;

/// 5 分钟对齐窗口（秒）。
const ROUND_DOWN_SECONDS: u64 = 300;

/// 上游 `TRUSTED_CLIENT_TOKEN` 常量（固定值，跨版本不变）。
pub const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";

/// 全局 clock skew（秒）。PoC 阶段简单起见用 `AtomicI64`，生产环境可改 `RwLock<f64>`。
static CLOCK_SKEW_NANOS: AtomicI64 = AtomicI64::new(0);

#[derive(Debug, Error)]
pub enum DrmError {
    #[error("system time is before unix epoch")]
    SystemTimeError,
}

/// 直接设置时钟偏差（秒），覆盖旧值。
///
/// 累加式的 [`adj_clock_skew_seconds`] 无法把偏移量归零，
/// 测试与「服务端一次校准到位」的场景需要这个绝对版本。
pub fn set_clock_skew_seconds(skew_seconds: f64) {
    let nanos = (skew_seconds * 1e9) as i64;
    CLOCK_SKEW_NANOS.store(nanos, Ordering::SeqCst);
}

/// 调整时钟偏差（秒）。调用方在收到服务端 `Date` header 后调用。
///
/// 上游在 401/403 后会读服务端 `Date`，算出 `server_date - client_date` 作为 skew。
pub fn adj_clock_skew_seconds(skew_seconds: f64) {
    let nanos = (skew_seconds * 1e9) as i64;
    CLOCK_SKEW_NANOS.fetch_add(nanos, Ordering::SeqCst);
}

/// 获取**未经 skew 校准**的当前 Unix 时间戳（秒）。
///
/// 需要与目标时间对齐时用它算差值，避免"读到的时间已含旧 skew"的套娃问题。
pub fn now_unix_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as f64
        / 1000.0
}

/// 获取当前 Unix 时间戳（含 skew 校准）。
pub fn get_unix_timestamp() -> f64 {
    let skew_seconds = CLOCK_SKEW_NANOS.load(Ordering::SeqCst) as f64 / 1e9;
    now_unix_seconds() + skew_seconds
}

/// 生成 Sec-MS-GEC Token。
///
/// 返回大写 hex SHA256 字符串。
///
/// # 示例
///
/// ```
/// use sayit_drm::generate_sec_ms_gec;
/// let token = generate_sec_ms_gec();
/// assert_eq!(token.len(), 64); // SHA256 hex 长度
/// assert!(token.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
/// ```
pub fn generate_sec_ms_gec() -> String {
    let mut ticks = get_unix_timestamp();

    // 切到 Windows file time 起点
    ticks += WIN_EPOCH_SECONDS as f64;

    // 向下取整到 5 分钟（300 秒）
    ticks -= ticks % ROUND_DOWN_SECONDS as f64;

    // 100ns 间隔：ticks（秒）* 1e9/100 = ticks * 10_000_000
    let ticks_100ns = ticks * 1e9 / 100.0;

    let s = format!("{ticks_100ns:.0}{TRUSTED_CLIENT_TOKEN}");

    let digest = Sha256::digest(s.as_bytes());
    hex::encode(digest).to_uppercase()
}

/// 生成随机 MUID（16 字节 hex，大写）。
///
/// 与上游 `secrets.token_hex(16).upper()` 等价。
///
/// 微软服务端要求 MUID 是 **16 字节无规律 hex**（实测：后段全 0 的 MUID 会触发 403）。
/// 这里用时间戳 + 计数器 + 多个独立 xorshift 状态填满 16 字节。
pub fn generate_muid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let count = COUNTER.fetch_add(1, Ordering::SeqCst);
    let pid = std::process::id() as u64;

    // 用 4 个独立 xorshift64 状态拼成 32 字节，再截取前 16 字节
    let mut buf = [0u8; 32];
    let seeds = [
        nanos.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(count),
        nanos.rotate_left(17).wrapping_add(pid),
        nanos.rotate_left(31).wrapping_sub(count),
        nanos.rotate_left(47) ^ pid,
    ];
    for (chunk, mut s) in buf.chunks_mut(8).zip(seeds) {
        // 每个 chunk 用独立 state 跑 xorshift
        for b in chunk.iter_mut() {
            s ^= s >> 30;
            s = s.wrapping_mul(0xBF58_476D_1CE4_E5B9);
            s ^= s >> 27;
            s = s.wrapping_mul(0x94D0_49BB_1331_11EB);
            s ^= s >> 31;
            *b = (s & 0xFF) as u8;
        }
    }
    hex::encode(&buf[..16]).to_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// `CLOCK_SKEW_NANOS` 是**进程级全局**状态，而 `cargo test` 默认多线程并行执行。
    /// 任何会改动它的测试都必须先抢这把锁，否则互相污染 → 随机失败。
    static SKEW_LOCK: Mutex<()> = Mutex::new(());

    /// 抢锁并**把 skew 归零**，返回一个 guard；测试结束自动释放。
    fn skew_guard() -> MutexGuard<'static, ()> {
        let guard = SKEW_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_clock_skew_seconds(0.0);
        guard
    }

    /// 把"当前时间"对齐到目标 Unix 时间戳（绝对设置，不累加）。
    fn freeze_at(target_unix: f64) {
        set_clock_skew_seconds(target_unix - now_unix_seconds());
    }

    #[test]
    fn token_is_64_hex_uppercase() {
        let t = generate_sec_ms_gec();
        assert_eq!(t.len(), 64, "SHA256 hex 应为 64 字符");
        assert!(t.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
    }

    #[test]
    fn token_changes_after_clock_skew() {
        let _g = skew_guard();
        let a = generate_sec_ms_gec();
        adj_clock_skew_seconds(3600.0); // +1 小时
        let b = generate_sec_ms_gec();
        assert_ne!(a, b);
        set_clock_skew_seconds(0.0); // 撤销
    }

    #[test]
    fn token_format_is_stable() {
        // 不验证"同一窗口 token 相等"——那需要 5 分钟内运行，
        // 单测跑得太慢可能跨窗口。改为验证：连续两次调用都满足 token 格式约束。
        let a = generate_sec_ms_gec();
        let b = generate_sec_ms_gec();
        for t in [&a, &b] {
            assert_eq!(t.len(), 64);
            assert!(t.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
        }
    }

    #[test]
    fn token_changes_after_clock_skew_jumps_window() {
        // +3700 秒（略多于一小时），不是 300（5分钟）的整数倍
        // 这样无论当前时间在窗口的哪个位置，skew 后都会落在不同窗口
        let _g = skew_guard();
        let before = generate_sec_ms_gec();
        adj_clock_skew_seconds(3700.0);
        let after = generate_sec_ms_gec();
        assert_ne!(before, after);
        set_clock_skew_seconds(0.0); // 撤销
    }

    #[test]
    fn muid_is_32_hex_uppercase() {
        let m = generate_muid();
        assert_eq!(m.len(), 32, "MUID 应为 16 字节 hex = 32 字符");
        assert!(m.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()));
    }

    #[test]
    fn muid_is_not_all_zero_tail() {
        // 后段全 0 的 MUID 会被服务端 403（见 generate_muid 文档）
        let m = generate_muid();
        assert_ne!(&m[16..], "0000000000000000");
        assert_ne!(m, "0".repeat(32));
    }

    #[test]
    fn trusted_client_token_constant() {
        assert_eq!(TRUSTED_CLIENT_TOKEN, "6A5AA1D4EAFF4E9FB37E23D68491D6F4");
    }

    #[test]
    fn gold_vector_same_window() {
        // Python 参考实现确认的 gold vector：
        // 1704067200.0 + 11644473600 = 13348540800
        // 13348540800 % 300 = 0（同窗口）
        // ticks_100ns = 13348540800 * 1e9 / 100 = 133485408000000000
        // token = SHA256("1334854080000000006A5AA1D4EAFF4E9FB37E23D68491D6F4")
        //       = "2AC0A57C1214B9458F8725BB7800499BB594EC29DDA83424BC14661707141F2F"
        let _g = skew_guard();
        freeze_at(1704067200.0);
        let token = generate_sec_ms_gec();

        assert_eq!(
            token, "2AC0A57C1214B9458F8725BB7800499BB594EC29DDA83424BC14661707141F2F",
            "Gold vector 验证失败"
        );
        set_clock_skew_seconds(0.0);
    }

    #[test]
    fn gold_vector_cross_window() {
        // 1704067200 → %300 = 0；+300 秒后跨到下一个 5 分钟窗口
        let _g = skew_guard();
        freeze_at(1704067200.0);
        let token1 = generate_sec_ms_gec();
        freeze_at(1704067500.0);
        let token2 = generate_sec_ms_gec();

        assert_ne!(token1, token2, "跨 5 分钟窗口 token 应不同");
        set_clock_skew_seconds(0.0);
    }

    #[test]
    fn ticks_100ns_calculation() {
        // 纯算术验证，不碰全局 skew（以前依赖"把时间重置到 0"，两次调用只要跨 1ms
        // 就会多出 10000 ticks，断言必然失败）。
        // 1 秒 = 10_000_000 ticks (100ns each)
        // 整数秒：先乘 1e9 再除 100 与直接乘 1e7 在位上都精确相等
        for unix_seconds in [0u64, 1, 1704067200] {
            let ticks = unix_seconds as f64 + WIN_EPOCH_SECONDS as f64;
            let expected = ticks * 1e9 / 100.0;
            let want = (WIN_EPOCH_SECONDS + unix_seconds) as f64 * 10_000_000.0;
            assert_eq!(expected, want, "tick 换算在 {unix_seconds}s 处不一致");
        }
        assert_eq!(
            (WIN_EPOCH_SECONDS as f64 * 1e9 / 100.0) as u64,
            WIN_EPOCH_SECONDS * 10_000_000
        );

        // 非整数秒：(WIN_EPOCH + 0.5) * 1e7 = 116444736005000000 ticks。
        // 浮点先乘 1e9 再除 100 会有 ULP 级别的误差，用容差比较。
        let ticks = 0.5 + WIN_EPOCH_SECONDS as f64;
        let expected = ticks * 1e9 / 100.0;
        assert!(
            (expected - 116_444_736_005_000_000.0).abs() < 1.0,
            "0.5s 应换算为 116444736005000000 ticks，实际 {expected}"
        );
    }
}
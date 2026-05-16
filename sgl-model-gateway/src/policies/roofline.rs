//! RoofLine Policy for hardware-aware heterogeneous GPU scheduling
//!
//! This policy scores workers based on their GPU hardware capabilities (TFLOPS,
//! memory bandwidth, VRAM) and selects the best-fit worker for each request.
//!
//! ## Strategy Details
//!
//! GPU capability extraction:
//! - **Built-in database**: Recognizes common GPU names (H800, H20, A100, RTX 4090, etc.)
//! - **Label extraction**: Falls back to individual labels (`tflops`, `bandwidth`, `vram`)
//! - **Default tier**: Unlabeled workers default to Tier 3 (economy class)
//!
//! Scoring formula:
//! ```text
//! score = w_compute * normalized_tflops + w_memory * normalized_bandwidth
//! ```
//!
//! Tier-based routing (simplified mode):
//! ```text
//! Tier 1 (H800 class)   → compute-intensive requests (large batch, long outputs)
//! Tier 2 (H20 class)    → memory-intensive requests (long context)
//! Tier 3 (4090 class)   → economy requests (short, simple)
//! ```
//!
//! ## Worker Labels
//!
//! Workers declare their GPU via labels:
//! ```text
//! --worker-label gpu_name=H800
//! --worker-label gpu_tier=Tier1
//! --worker-label tflops=989
//! --worker-label bandwidth=2039
//! --worker-label vram=80
//! ```
//!
//! Priority: `gpu_name` (built-in DB) > individual labels > default Tier 3

#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tracing::debug;

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

// ─── GPU Capability Data ──────────────────────────────────────────────────────

/// Three GPU performance tiers
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum GpuTier {
    /// Economy — RTX 4090 class, suitable for short/simple requests
    Tier3 = 0,
    /// Balanced — H20 class, large VRAM for long-context decoding
    Tier2 = 1,
    /// Premium — H800 class, high TFLOPS for compute-intensive Prefill
    Tier1 = 2,
}

impl std::fmt::Display for GpuTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GpuTier::Tier1 => write!(f, "Tier1"),
            GpuTier::Tier2 => write!(f, "Tier2"),
            GpuTier::Tier3 => write!(f, "Tier3"),
        }
    }
}

impl GpuTier {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "tier1" | "tier_1" | "h800" | "h100" | "a100" => Some(GpuTier::Tier1),
            "tier2" | "tier_2" | "h20" | "l40s" => Some(GpuTier::Tier2),
            "tier3" | "tier_3" | "4090" | "3090" | "l20" => Some(GpuTier::Tier3),
            _ => None,
        }
    }
}

/// Hardware capability profile for a GPU
#[derive(Debug, Clone, PartialEq)]
pub struct GpuCapability {
    pub name: String,
    pub tier: GpuTier,
    pub fp16_tflops: f64,
    pub mem_bandwidth_gb_s: f64,
    pub vram_gb: f64,
}

impl GpuCapability {
    /// Create a default (conservative, Tier 3) capability
    fn default_tier3() -> Self {
        Self {
            name: "unknown".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 20.0,
            mem_bandwidth_gb_s: 200.0,
            vram_gb: 16.0,
        }
    }
}

/// Built-in GPU capability database.
///
/// Maps known GPU names to their hardware profiles. New GPUs can be added here.
fn get_builtin_gpu_db() -> HashMap<&'static str, GpuCapability> {
    let mut db = HashMap::new();

    // ── Tier 1: Premium compute GPUs ──
    db.insert(
        "H800",
        GpuCapability {
            name: "H800".to_string(),
            tier: GpuTier::Tier1,
            fp16_tflops: 989.0,
            mem_bandwidth_gb_s: 2039.0,
            vram_gb: 80.0,
        },
    );
    db.insert(
        "H100",
        GpuCapability {
            name: "H100".to_string(),
            tier: GpuTier::Tier1,
            fp16_tflops: 989.0,
            mem_bandwidth_gb_s: 2039.0,
            vram_gb: 80.0,
        },
    );
    db.insert(
        "A100",
        GpuCapability {
            name: "A100".to_string(),
            tier: GpuTier::Tier1,
            fp16_tflops: 312.0,
            mem_bandwidth_gb_s: 2039.0,
            vram_gb: 80.0,
        },
    );
    db.insert(
        "A800",
        GpuCapability {
            name: "A800".to_string(),
            tier: GpuTier::Tier1,
            fp16_tflops: 312.0,
            mem_bandwidth_gb_s: 2039.0,
            vram_gb: 80.0,
        },
    );

    // ── Tier 2: Balanced memory GPUs ──
    db.insert(
        "H20",
        GpuCapability {
            name: "H20".to_string(),
            tier: GpuTier::Tier2,
            fp16_tflops: 148.0,
            mem_bandwidth_gb_s: 4000.0,
            vram_gb: 96.0,
        },
    );
    db.insert(
        "L40S",
        GpuCapability {
            name: "L40S".to_string(),
            tier: GpuTier::Tier2,
            fp16_tflops: 91.6,
            mem_bandwidth_gb_s: 864.0,
            vram_gb: 48.0,
        },
    );

    // ── Tier 3: Economy GPUs ──
    db.insert(
        "RTX 4090",
        GpuCapability {
            name: "RTX 4090".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 82.6,
            mem_bandwidth_gb_s: 1008.0,
            vram_gb: 24.0,
        },
    );
    db.insert(
        "4090",
        GpuCapability {
            name: "RTX 4090".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 82.6,
            mem_bandwidth_gb_s: 1008.0,
            vram_gb: 24.0,
        },
    );
    db.insert(
        "RTX 3090",
        GpuCapability {
            name: "RTX 3090".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 35.6,
            mem_bandwidth_gb_s: 936.0,
            vram_gb: 24.0,
        },
    );
    db.insert(
        "3090",
        GpuCapability {
            name: "RTX 3090".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 35.6,
            mem_bandwidth_gb_s: 936.0,
            vram_gb: 24.0,
        },
    );
    db.insert(
        "L20",
        GpuCapability {
            name: "L20".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 59.8,
            mem_bandwidth_gb_s: 288.0,
            vram_gb: 24.0,
        },
    );
    db.insert(
        "RTX 4070 Ti SUPER",
        GpuCapability {
            name: "RTX 4070 Ti SUPER".to_string(),
            tier: GpuTier::Tier3,
            fp16_tflops: 44.1,
            mem_bandwidth_gb_s: 672.0,
            vram_gb: 16.0,
        },
    );

    db
}

// ─── Configuration ───────────────────────────────────────────────────────────

/// Configuration for RoofLine hardware-aware policy
#[derive(Debug, Clone)]
pub struct RoofLineConfig {
    /// Weight for compute capability (TFLOPS) in scoring
    pub weight_compute: f64,
    /// Weight for memory bandwidth in scoring
    pub weight_memory: f64,
}

impl Default for RoofLineConfig {
    fn default() -> Self {
        Self {
            weight_compute: 0.5,
            weight_memory: 0.5,
        }
    }
}

// ─── Request Feature Estimation ──────────────────────────────────────────────

/// Estimated request characteristics for GPU matching
#[derive(Debug, Clone, Default)]
struct RequestFeatures {
    /// Estimated input context length (characters)
    input_length: usize,
    /// Estimated output length (from max_tokens)
    output_tokens: usize,
    /// Whether streaming mode is requested
    is_stream: bool,
}

// ─── Policy Implementation ───────────────────────────────────────────────────

/// RoofLine Policy — Hardware-aware scheduling based on GPU roofline model.
///
/// Scores workers by their GPU capabilities (TFLOPS, memory bandwidth) and
/// selects the best match for each request based on compute/memory needs.
#[derive(Debug)]
pub struct RoofLinePolicy {
    config: RoofLineConfig,
    /// Built-in GPU capability database: GPU name → capability
    gpu_db: HashMap<&'static str, GpuCapability>,
}

impl RoofLinePolicy {
    pub fn new() -> Self {
        Self::with_config(RoofLineConfig::default())
    }

    pub fn with_config(config: RoofLineConfig) -> Self {
        Self {
            config,
            gpu_db: get_builtin_gpu_db(),
        }
    }

    /// Resolve a worker's GPU capability from its labels
    fn resolve_gpu_capability(&self, worker: &dyn Worker) -> GpuCapability {
        let labels = &worker.metadata().labels;

        // Priority 1: Built-in DB lookup by gpu_name label
        if let Some(gpu_name) = labels.get("gpu_name") {
            if let Some(cap) = self.gpu_db.get(gpu_name.as_str()) {
                return cap.clone();
            }
        }

        // Priority 2: Tier label
        if let Some(tier_str) = labels.get("gpu_tier") {
            if let Some(tier) = GpuTier::from_str(tier_str) {
                // Try to get detailed specs from individual labels
                let tflops = labels
                    .get("tflops")
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or_else(|| match tier {
                        GpuTier::Tier1 => 500.0,
                        GpuTier::Tier2 => 100.0,
                        GpuTier::Tier3 => 30.0,
                    });
                let bandwidth = labels
                    .get("bandwidth")
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or_else(|| match tier {
                        GpuTier::Tier1 => 1500.0,
                        GpuTier::Tier2 => 4000.0,
                        GpuTier::Tier3 => 500.0,
                    });
                let vram = labels
                    .get("vram")
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or_else(|| match tier {
                        GpuTier::Tier1 => 80.0,
                        GpuTier::Tier2 => 96.0,
                        GpuTier::Tier3 => 24.0,
                    });

                return GpuCapability {
                    name: format!("tier:{tier}"),
                    tier,
                    fp16_tflops: tflops,
                    mem_bandwidth_gb_s: bandwidth,
                    vram_gb: vram,
                };
            }
        }

        // Priority 3: Parse individual numeric labels
        let tflops = labels
            .get("tflops")
            .and_then(|v| v.parse::<f64>().ok());
        let bandwidth = labels
            .get("bandwidth")
            .and_then(|v| v.parse::<f64>().ok());
        let vram = labels
            .get("vram")
            .and_then(|v| v.parse::<f64>().ok());

        if tflops.is_some() || bandwidth.is_some() {
            return GpuCapability {
                name: "custom".to_string(),
                tier: Self::infer_tier(tflops, bandwidth, vram),
                fp16_tflops: tflops.unwrap_or(20.0),
                mem_bandwidth_gb_s: bandwidth.unwrap_or(200.0),
                vram_gb: vram.unwrap_or(16.0),
            };
        }

        // Priority 4: Default (conservative Tier 3)
        GpuCapability::default_tier3()
    }

    /// Infer GPU tier from raw specs
    fn infer_tier(tflops: Option<f64>, bandwidth: Option<f64>, _vram: Option<f64>) -> GpuTier {
        let t = tflops.unwrap_or(0.0);
        let b = bandwidth.unwrap_or(0.0);
        if t >= 300.0 || b >= 2000.0 {
            GpuTier::Tier1
        } else if t >= 80.0 || b >= 800.0 {
            GpuTier::Tier2
        } else {
            GpuTier::Tier3
        }
    }

    /// Score a set of workers based on their GPU capabilities.
    ///
    /// Returns a list of (worker_index, score) sorted by score descending.
    /// Workers are scored by: w_compute * norm_tflops + w_memory * norm_bandwidth
    fn score_workers(&self, workers: &[Arc<dyn Worker>]) -> Vec<(usize, f64)> {
        let healthy_indices = get_healthy_worker_indices(workers);
        if healthy_indices.is_empty() {
            return vec![];
        }

        // Resolve capabilities for healthy workers
        let caps: Vec<(usize, GpuCapability)> = healthy_indices
            .iter()
            .map(|&idx| (idx, self.resolve_gpu_capability(workers[idx].as_ref())))
            .collect();

        // Find max values for normalization
        let max_tflops = caps
            .iter()
            .map(|(_, c)| c.fp16_tflops)
            .fold(1.0_f64, f64::max);
        let max_bandwidth = caps
            .iter()
            .map(|(_, c)| c.mem_bandwidth_gb_s)
            .fold(1.0_f64, f64::max);

        // Compute scores
        let mut scored: Vec<(usize, f64)> = caps
            .iter()
            .map(|(idx, cap)| {
                let norm_tflops = cap.fp16_tflops / max_tflops;
                let norm_bandwidth = cap.mem_bandwidth_gb_s / max_bandwidth;
                let score = self.config.weight_compute * norm_tflops
                    + self.config.weight_memory * norm_bandwidth;
                (*idx, score)
            })
            .collect();

        // Sort by score descending (then by index for determinism)
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
        scored
    }

    /// Estimate request features from request text
    fn estimate_request_features(&self, info: &SelectWorkerInfo<'_>) -> RequestFeatures {
        let request_text = info.request_text.unwrap_or("");

        let input_length = request_text.len();
        let output_tokens = Self::extract_max_tokens(request_text);
        let is_stream = Self::extract_stream(request_text);

        RequestFeatures {
            input_length,
            output_tokens,
            is_stream,
        }
    }

    /// Extract `max_tokens` from request JSON (fast substring search)
    fn extract_max_tokens(text: &str) -> usize {
        if let Some(pos) = text.find("\"max_tokens\"") {
            let after = &text[pos + 12..];
            if let Some(colon_pos) = after.find(':') {
                let after_colon = after[colon_pos + 1..].trim_start();
                let num_str: String = after_colon
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                if let Ok(val) = num_str.parse::<usize>() {
                    return val;
                }
            }
        }
        if let Some(pos) = text.find("\"max_completion_tokens\"") {
            let after = &text[pos + 23..];
            if let Some(colon_pos) = after.find(':') {
                let after_colon = after[colon_pos + 1..].trim_start();
                let num_str: String = after_colon
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                if let Ok(val) = num_str.parse::<usize>() {
                    return val;
                }
            }
        }
        512
    }

    /// Extract `stream` field from request text
    fn extract_stream(text: &str) -> bool {
        if let Some(pos) = text.find("\"stream\"") {
            let after = &text[pos + 8..];
            if let Some(colon_pos) = after.find(':') {
                let after_colon = after[colon_pos + 1..].trim_start();
                return after_colon.starts_with("true");
            }
        }
        false
    }
}

impl Default for RoofLinePolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LoadBalancingPolicy for RoofLinePolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);
        if healthy_indices.is_empty() {
            return None;
        }

        // Score all workers by GPU capability
        let scored = self.score_workers(workers);

        if scored.is_empty() {
            return None;
        }

        let best_idx = scored[0].0;

        let features = self.estimate_request_features(info);
        let cap = self.resolve_gpu_capability(workers[best_idx].as_ref());
        debug!(
            "[RoofLine] Selected worker[{}] ({}): score={:.3}, tier={}, tflops={:.1}, bw={:.1} | request: input={}, output={}, stream={}",
            best_idx,
            cap.name,
            scored[0].1,
            cap.tier,
            cap.fp16_tflops,
            cap.mem_bandwidth_gb_s,
            features.input_length,
            features.output_tokens,
            features.is_stream,
        );

        Some(best_idx)
    }

    fn on_request_complete(&self, _worker_url: &str, _success: bool) {}

    fn name(&self) -> &'static str {
        "roofline"
    }

    fn needs_request_text(&self) -> bool {
        true
    }

    fn reset(&self) {}

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    fn make_worker(url: &str, labels: Vec<(&str, &str)>) -> Arc<dyn Worker> {
        let mut builder = BasicWorkerBuilder::new(url).worker_type(WorkerType::Regular);
        for (k, v) in labels {
            builder = builder.label(k, v);
        }
        Arc::new(builder.build())
    }

    fn make_worker_no_labels(url: &str) -> Arc<dyn Worker> {
        Arc::new(
            BasicWorkerBuilder::new(url)
                .worker_type(WorkerType::Regular)
                .build(),
        )
    }

    // ── GPU DB / Capability Resolution ────────────────────────────────────

    #[test]
    fn test_builtin_db_has_expected_gpus() {
        let db = get_builtin_gpu_db();
        assert!(db.contains_key("H800"));
        assert!(db.contains_key("H100"));
        assert!(db.contains_key("A100"));
        assert!(db.contains_key("H20"));
        assert!(db.contains_key("L40S"));
        assert!(db.contains_key("RTX 4090"));
        assert!(db.contains_key("4090"));
        assert!(db.contains_key("RTX 3090"));
    }

    #[test]
    fn test_gpu_tier_ordering() {
        assert!(GpuTier::Tier1 > GpuTier::Tier2);
        assert!(GpuTier::Tier2 > GpuTier::Tier3);
    }

    #[test]
    fn test_gpu_tier_from_str() {
        assert_eq!(GpuTier::from_str("Tier1"), Some(GpuTier::Tier1));
        assert_eq!(GpuTier::from_str("H800"), Some(GpuTier::Tier1));
        assert_eq!(GpuTier::from_str("h100"), Some(GpuTier::Tier1));
        assert_eq!(GpuTier::from_str("Tier2"), Some(GpuTier::Tier2));
        assert_eq!(GpuTier::from_str("h20"), Some(GpuTier::Tier2));
        assert_eq!(GpuTier::from_str("Tier3"), Some(GpuTier::Tier3));
        assert_eq!(GpuTier::from_str("4090"), Some(GpuTier::Tier3));
        assert_eq!(GpuTier::from_str("unknown"), None);
    }

    #[test]
    fn test_resolve_by_gpu_name() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker("http://w1:8000", vec![("gpu_name", "H800")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier1);
        assert!((cap.fp16_tflops - 989.0).abs() < 0.1);
        assert!((cap.mem_bandwidth_gb_s - 2039.0).abs() < 0.1);
        assert!((cap.vram_gb - 80.0).abs() < 0.1);
    }

    #[test]
    fn test_resolve_by_gpu_name_h20() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker("http://w1:8000", vec![("gpu_name", "H20")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier2);
        assert!((cap.fp16_tflops - 148.0).abs() < 0.1);
        assert!((cap.mem_bandwidth_gb_s - 4000.0).abs() < 0.1);
    }

    #[test]
    fn test_resolve_by_gpu_name_rtx4090() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker("http://w1:8000", vec![("gpu_name", "RTX 4090")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier3);
        assert!((cap.fp16_tflops - 82.6).abs() < 0.2);
    }

    #[test]
    fn test_resolve_by_tier_label() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker("http://w1:8000", vec![("gpu_tier", "Tier1")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier1);
        assert!((cap.fp16_tflops - 500.0).abs() < 0.1); // Tier1 default tflops

        let worker = make_worker("http://w2:8000", vec![("gpu_tier", "Tier2")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier2);

        let worker = make_worker("http://w3:8000", vec![("gpu_tier", "Tier3")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier3);
    }

    #[test]
    fn test_resolve_by_tier_with_overrides() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker(
            "http://w1:8000",
            vec![
                ("gpu_tier", "Tier1"),
                ("tflops", "600"),
                ("bandwidth", "3000"),
                ("vram", "48"),
            ],
        );
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier1);
        assert!((cap.fp16_tflops - 600.0).abs() < 0.1);
        assert!((cap.mem_bandwidth_gb_s - 3000.0).abs() < 0.1);
        assert!((cap.vram_gb - 48.0).abs() < 0.1);
    }

    #[test]
    fn test_resolve_by_individual_labels() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker(
            "http://w1:8000",
            vec![("tflops", "100"), ("bandwidth", "600"), ("vram", "32")],
        );
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert!((cap.fp16_tflops - 100.0).abs() < 0.1);
        assert!((cap.mem_bandwidth_gb_s - 600.0).abs() < 0.1);
        assert!((cap.vram_gb - 32.0).abs() < 0.1);
        // 100 tflops >= 80 → Tier2, 600 bandwidth < 800 → but tflops check wins
        assert_eq!(cap.tier, GpuTier::Tier2);
    }

    #[test]
    fn test_resolve_default_for_unlabeled() {
        let policy = RoofLinePolicy::new();
        let worker = make_worker_no_labels("http://w1:8000");
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier3);
        assert!((cap.fp16_tflops - 20.0).abs() < 0.1);
    }

    #[test]
    fn test_resolve_gpu_name_takes_priority_over_tier() {
        let policy = RoofLinePolicy::new();
        // gpu_name=H800 wins over gpu_tier=Tier3 (contradicting labels)
        let worker = make_worker(
            "http://w1:8000",
            vec![("gpu_name", "H800"), ("gpu_tier", "Tier3")],
        );
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        assert_eq!(cap.tier, GpuTier::Tier1);
    }

    // ── Scoring ───────────────────────────────────────────────────────────

    #[test]
    fn test_score_workers_highest_tflops_wins_with_compute_weight() {
        let config = RoofLineConfig {
            weight_compute: 1.0,
            weight_memory: 0.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]), // 989 tflops
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),  // 148 tflops
            make_worker("http://w3:8000", vec![("gpu_name", "RTX 4090")]), // 82.6 tflops
        ];

        let scored = policy.score_workers(&workers);
        assert_eq!(scored[0].0, 0); // H800 wins (highest tflops)
        assert_eq!(scored[1].0, 1); // H20 second
        assert_eq!(scored[2].0, 2); // 4090 last
    }

    #[test]
    fn test_score_workers_highest_bandwidth_wins_with_memory_weight() {
        let config = RoofLineConfig {
            weight_compute: 0.0,
            weight_memory: 1.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]), // 2039 GB/s
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),  // 4000 GB/s
            make_worker("http://w3:8000", vec![("gpu_name", "RTX 4090")]), // 1008 GB/s
        ];

        let scored = policy.score_workers(&workers);
        assert_eq!(scored[0].0, 1); // H20 wins (highest bandwidth)
        assert_eq!(scored[1].0, 0); // H800 second
        assert_eq!(scored[2].0, 2); // 4090 last
    }

    #[test]
    fn test_score_workers_balanced_weights() {
        let config = RoofLineConfig {
            weight_compute: 0.5,
            weight_memory: 0.5,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]), // high both
            make_worker("http://w2:8000", vec![("gpu_name", "RTX 3090")]), // low both
        ];

        let scored = policy.score_workers(&workers);
        assert_eq!(scored[0].0, 0); // H800 should win
        assert_eq!(scored[1].0, 1);
        assert!(scored[0].1 > scored[1].1);
    }

    #[test]
    fn test_score_workers_single_worker() {
        let policy = RoofLinePolicy::new();
        let workers: Vec<Arc<dyn Worker>> =
            vec![make_worker("http://w1:8000", vec![("gpu_name", "H20")])];
        let scored = policy.score_workers(&workers);
        assert_eq!(scored.len(), 1);
        assert_eq!(scored[0].0, 0);
        assert!((scored[0].1 - 1.0).abs() < 0.01); // normalized = 1.0 for sole worker
    }

    #[test]
    fn test_score_workers_all_unhealthy_returns_empty() {
        let policy = RoofLinePolicy::new();
        let workers: Vec<Arc<dyn Worker>> = vec![make_worker(
            "http://w1:8000",
            vec![("gpu_name", "H800")],
        )];
        workers[0].set_healthy(false);

        let scored = policy.score_workers(&workers);
        assert!(scored.is_empty());
    }

    #[test]
    fn test_score_workers_skips_unhealthy() {
        let policy = RoofLinePolicy::new();
        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]),
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),
        ];
        // Make H800 unhealthy → H20 should be the only scored worker
        workers[0].set_healthy(false);

        let scored = policy.score_workers(&workers);
        assert_eq!(scored.len(), 1);
        assert_eq!(scored[0].0, 1); // H20
    }

    #[test]
    fn test_score_workers_custom_labels() {
        let config = RoofLineConfig {
            weight_compute: 1.0,
            weight_memory: 0.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker(
                "http://w1:8000",
                vec![("tflops", "200"), ("bandwidth", "1000")],
            ),
            make_worker(
                "http://w2:8000",
                vec![("tflops", "50"), ("bandwidth", "2000")],
            ),
        ];

        let scored = policy.score_workers(&workers);
        assert_eq!(scored[0].0, 0); // w1 has higher tflops (200 > 50)
        assert!(scored[0].1 > scored[1].1);
    }

    // ── select_worker integration ─────────────────────────────────────────

    #[tokio::test]
    async fn test_select_worker_h800_over_h20_for_compute() {
        let config = RoofLineConfig {
            weight_compute: 1.0,
            weight_memory: 0.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]),
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),
        ];

        let info = SelectWorkerInfo {
            request_text: Some(r#"{"max_tokens":100}"#),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0)); // H800 best compute
    }

    #[tokio::test]
    async fn test_select_worker_h20_over_h800_for_memory() {
        let config = RoofLineConfig {
            weight_compute: 0.0,
            weight_memory: 1.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]), // 2039 GB/s
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),  // 4000 GB/s
        ];

        let info = SelectWorkerInfo {
            request_text: Some("long context request"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(1)); // H20 best memory bandwidth
    }

    #[tokio::test]
    async fn test_select_worker_unhealthy_skipped() {
        let policy = RoofLinePolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]),
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),
        ];

        workers[0].set_healthy(false);

        let info = SelectWorkerInfo {
            request_text: Some("test"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(1)); // H20 is only healthy worker
    }

    #[tokio::test]
    async fn test_select_worker_no_healthy_returns_none() {
        let policy = RoofLinePolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]),
            make_worker("http://w2:8000", vec![("gpu_name", "H20")]),
        ];

        workers[0].set_healthy(false);
        workers[1].set_healthy(false);

        let info = SelectWorkerInfo {
            request_text: Some("test"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, None);
    }

    #[tokio::test]
    async fn test_select_worker_no_labels_defaults_all_equal() {
        let policy = RoofLinePolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker_no_labels("http://w1:8000"),
            make_worker_no_labels("http://w2:8000"),
        ];

        let info = SelectWorkerInfo {
            request_text: Some("test"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        // Both default to Tier3 with same specs → equal scores → pick first
        assert_eq!(idx, Some(0));
    }

    #[tokio::test]
    async fn test_select_worker_with_mixed_gpu_tiers() {
        let policy = RoofLinePolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "RTX 4090")]), // Tier3
            make_worker("http://w2:8000", vec![("gpu_name", "H800")]),     // Tier1
            make_worker("http://w3:8000", vec![("gpu_name", "H20")]),      // Tier2
        ];

        let info = SelectWorkerInfo {
            request_text: Some("compute heavy request"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        // Balanced weights → H800 should win (highest combined score)
        assert_eq!(idx, Some(1));
    }

    // ── Request Feature Estimation ────────────────────────────────────────

    #[test]
    fn test_feature_extraction() {
        let policy = RoofLinePolicy::new();
        let text = r#"{"max_tokens":2048,"stream":true,"messages":[{"content":"hello world"}]}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let features = policy.estimate_request_features(&info);
        assert_eq!(features.input_length, text.len());
        assert_eq!(features.output_tokens, 2048);
        assert!(features.is_stream);
    }

    #[test]
    fn test_feature_extraction_defaults() {
        let policy = RoofLinePolicy::new();
        let info = SelectWorkerInfo {
            request_text: None,
            ..Default::default()
        };
        let features = policy.estimate_request_features(&info);
        assert_eq!(features.input_length, 0);
        assert_eq!(features.output_tokens, 512);
        assert!(!features.is_stream);
    }

    #[test]
    fn test_max_tokens_extraction() {
        assert_eq!(
            RoofLinePolicy::extract_max_tokens(r#"{"max_tokens":4096}"#),
            4096
        );
        assert_eq!(
            RoofLinePolicy::extract_max_tokens(r#"{"max_completion_tokens":2048}"#),
            2048
        );
        assert_eq!(
            RoofLinePolicy::extract_max_tokens(r#"{"model":"test"}"#),
            512
        );
    }

    #[test]
    fn test_stream_extraction() {
        assert!(RoofLinePolicy::extract_stream(r#"{"stream":true}"#));
        assert!(!RoofLinePolicy::extract_stream(r#"{"stream":false}"#));
        assert!(!RoofLinePolicy::extract_stream(r#"{"model":"test"}"#));
    }

    #[test]
    fn test_infer_tier() {
        assert_eq!(
            RoofLinePolicy::infer_tier(Some(500.0), Some(1000.0), None),
            GpuTier::Tier1
        );
        assert_eq!(
            RoofLinePolicy::infer_tier(Some(100.0), Some(500.0), None),
            GpuTier::Tier2
        );
        assert_eq!(
            RoofLinePolicy::infer_tier(Some(30.0), Some(200.0), None),
            GpuTier::Tier3
        );
        // Bandwidth-driven: high bandwidth triggers Tier1
        assert_eq!(
            RoofLinePolicy::infer_tier(Some(50.0), Some(2500.0), None),
            GpuTier::Tier1
        );
        assert_eq!(
            RoofLinePolicy::infer_tier(None, None, None),
            GpuTier::Tier3
        );
    }

    // ── Policy Metadata ───────────────────────────────────────────────────

    #[test]
    fn test_name_and_needs_request_text() {
        let policy = RoofLinePolicy::new();
        assert_eq!(policy.name(), "roofline");
        assert!(policy.needs_request_text());
    }

    #[test]
    fn test_default_policy() {
        let policy = RoofLinePolicy::default();
        assert_eq!(policy.name(), "roofline");
        // Default config should have balanced weights
        assert!((policy.config.weight_compute - 0.5).abs() < 0.01);
        assert!((policy.config.weight_memory - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_custom_config_weights() {
        let config = RoofLineConfig {
            weight_compute: 0.7,
            weight_memory: 0.3,
        };
        let policy = RoofLinePolicy::with_config(config);
        assert!((policy.config.weight_compute - 0.7).abs() < 0.01);
        assert!((policy.config.weight_memory - 0.3).abs() < 0.01);
    }

    #[test]
    fn test_resolve_unknown_gpu_name_falls_back() {
        let policy = RoofLinePolicy::new();
        // gpu_name=UnknownGPU → not in DB → falls through to tier/default
        let worker = make_worker("http://w1:8000", vec![("gpu_name", "UnknownGPU")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        // No tier or individual labels → default Tier3
        assert_eq!(cap.tier, GpuTier::Tier3);
    }

    #[test]
    fn test_resolve_gpu_name_case_sensitive() {
        let policy = RoofLinePolicy::new();
        // "h800" (lowercase) not in DB → falls through
        let worker = make_worker("http://w1:8000", vec![("gpu_name", "h800")]);
        let cap = policy.resolve_gpu_capability(worker.as_ref());
        // Not found in DB → falls through to default Tier3
        assert_eq!(cap.tier, GpuTier::Tier3);
    }

    #[test]
    fn test_normalization_with_identical_gpus() {
        let config = RoofLineConfig {
            weight_compute: 1.0,
            weight_memory: 0.0,
        };
        let policy = RoofLinePolicy::with_config(config);

        // All workers have same GPU → all scores should be 1.0
        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", vec![("gpu_name", "H800")]),
            make_worker("http://w2:8000", vec![("gpu_name", "H800")]),
        ];

        let scored = policy.score_workers(&workers);
        assert!((scored[0].1 - 1.0).abs() < 0.01);
        assert!((scored[1].1 - 1.0).abs() < 0.01);
        // Equal scores → first by index
        assert_eq!(scored[0].0, 0);
        assert_eq!(scored[1].0, 1);
    }

    #[test]
    fn test_gpu_tier_display() {
        assert_eq!(format!("{}", GpuTier::Tier1), "Tier1");
        assert_eq!(format!("{}", GpuTier::Tier2), "Tier2");
        assert_eq!(format!("{}", GpuTier::Tier3), "Tier3");
    }

    #[test]
    fn test_gpu_capability_default_tier3() {
        let cap = GpuCapability::default_tier3();
        assert_eq!(cap.tier, GpuTier::Tier3);
        assert_eq!(cap.name, "unknown");
        assert!((cap.fp16_tflops - 20.0).abs() < 0.1);
    }

    // ── Signal propagation (no-op) ────────────────────────────────────────

    #[tokio::test]
    async fn test_reset_is_noop() {
        let policy = RoofLinePolicy::new();
        // reset() is no-op for stateless policy; should not panic
        policy.reset();

        // Should still be able to select workers after reset
        let workers: Vec<Arc<dyn Worker>> =
            vec![make_worker("http://w1:8000", vec![("gpu_name", "H800")])];
        let info = SelectWorkerInfo {
            request_text: Some("test"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0));
    }

    #[test]
    fn test_update_loads_is_noop() {
        let policy = RoofLinePolicy::new();
        // update_loads is no-op for this stateless policy; should not panic
        policy.update_loads(&HashMap::new());
    }

    #[test]
    fn test_on_request_complete_is_noop() {
        let policy = RoofLinePolicy::new();
        policy.on_request_complete("http://w1:8000", true);
        policy.on_request_complete("http://w2:8000", false);
    }
}
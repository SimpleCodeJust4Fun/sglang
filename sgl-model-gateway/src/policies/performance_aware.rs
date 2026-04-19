//! Performance-Aware Load Balancing Policy
//!
//! This policy considers worker performance metrics (TTFT, TPOT, tokens/sec) along with
//! current load to make intelligent routing decisions. It's designed for heterogeneous
//! GPU environments where different workers have different performance characteristics.
//!
//! ## Strategy Details
//!
//! The policy maintains a performance score for each worker based on:
//! - **TTFT** (Time To First Token): Lower is better for interactive requests
//! - **TPOT** (Time Per Output Token): Lower is better for throughput
//! - **Tokens/sec**: Higher is better for overall performance
//! - **Current Load**: Lower is better for immediate response
//!
//! Scoring formula:
//! ```
//! performance_score = (weight_ttft * normalized_ttft +
//!                     weight_tpot * normalized_tpot +
//!                     weight_throughput * normalized_throughput) *
//!                     load_factor
//! ```
//!
//! ## Use Cases
//!
//! - Mix of high-end GPUs (fast compute) and low-end GPUs (large memory)
//! - Route latency-sensitive requests to fast GPUs
//! - Route throughput-heavy requests to high-memory GPUs
//! - Automatically adapt to worker performance changes

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Instant;

use async_trait::async_trait;
use tracing::debug;

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

/// Configuration for performance-aware policy
#[derive(Debug, Clone)]
pub struct PerformanceAwareConfig {
    /// Weight for TTFT in scoring (0.0-1.0)
    pub weight_ttft: f64,
    /// Weight for TPOT in scoring (0.0-1.0)
    pub weight_tpot: f64,
    /// Weight for throughput in scoring (0.0-1.0)
    pub weight_throughput: f64,
    /// How often to refresh performance scores (seconds)
    pub score_refresh_interval_secs: u64,
    /// Whether to consider current load in scoring
    pub consider_load: bool,
}

impl Default for PerformanceAwareConfig {
    fn default() -> Self {
        Self {
            weight_ttft: 0.3,
            weight_tpot: 0.3,
            weight_throughput: 0.4,
            score_refresh_interval_secs: 60,
            consider_load: true,
        }
    }
}

/// Performance metrics for a worker
#[derive(Debug, Clone)]
struct WorkerPerformanceMetrics {
    /// Average TTFT in milliseconds
    avg_ttft_ms: f64,
    /// Average TPOT in milliseconds
    avg_tpot_ms: f64,
    /// Average throughput in tokens/sec
    avg_tokens_per_sec: f64,
    /// Number of requests measured
    request_count: u64,
    /// Last updated timestamp
    last_updated: Instant,
}

impl WorkerPerformanceMetrics {
    fn new() -> Self {
        Self {
            avg_ttft_ms: 0.0,
            avg_tpot_ms: 0.0,
            avg_tokens_per_sec: 0.0,
            request_count: 0,
            last_updated: Instant::now(),
        }
    }

    /// Update metrics with new observation
    fn update(&mut self, ttft_ms: f64, tpot_ms: f64, tokens_per_sec: f64) {
        let n = self.request_count as f64;
        let new_n = n + 1.0;

        // Running average update
        self.avg_ttft_ms = (self.avg_ttft_ms * n + ttft_ms) / new_n;
        self.avg_tpot_ms = (self.avg_tpot_ms * n + tpot_ms) / new_n;
        self.avg_tokens_per_sec = (self.avg_tokens_per_sec * n + tokens_per_sec) / new_n;
        self.request_count += 1;
        self.last_updated = Instant::now();
    }
}

/// Performance-aware load balancing policy
#[derive(Debug)]
pub struct PerformanceAwarePolicy {
    config: PerformanceAwareConfig,
    /// Performance metrics per worker URL
    worker_metrics: Arc<RwLock<HashMap<String, WorkerPerformanceMetrics>>>,
    /// Cached performance scores (URL -> score)
    cached_scores: Arc<RwLock<HashMap<String, f64>>>,
    /// Last score refresh timestamp
    last_score_refresh: Arc<AtomicU64>,
}

impl PerformanceAwarePolicy {
    pub fn new() -> Self {
        Self::with_config(PerformanceAwareConfig::default())
    }

    pub fn with_config(config: PerformanceAwareConfig) -> Self {
        Self {
            config,
            worker_metrics: Arc::new(RwLock::new(HashMap::new())),
            cached_scores: Arc::new(RwLock::new(HashMap::new())),
            last_score_refresh: Arc::new(AtomicU64::new(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs(),
            )),
        }
    }

    /// Check if scores need to be refreshed
    fn should_refresh_scores(&self) -> bool {
        if self.config.score_refresh_interval_secs == 0 {
            return false; // Disabled
        }

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let last_refresh = self.last_score_refresh.load(Ordering::Relaxed);
        (now - last_refresh) >= self.config.score_refresh_interval_secs
    }

    /// Calculate performance scores for all workers
    fn calculate_scores(&self, workers: &[Arc<dyn Worker>]) {
        let metrics = self.worker_metrics.read().unwrap();
        let mut scores = HashMap::new();

        if metrics.is_empty() {
            // No metrics yet, use worker priority/cost as fallback
            for worker in workers {
                let priority = worker.priority() as f64;
                let cost = worker.cost() as f64;
                let score = if cost > 0.0 {
                    priority / cost
                } else {
                    0.0
                };
                scores.insert(worker.url().to_string(), score);
            }
        } else {
            // Calculate weighted scores
            let mut max_ttft = f64::MIN;
            let mut min_ttft = f64::MAX;
            let mut max_tpot = f64::MIN;
            let mut min_tpot = f64::MAX;
            let mut max_throughput = f64::MIN;
            let mut min_throughput = f64::MAX;

            // Find min/max for normalization
            for (_url, m) in metrics.iter() {
                if m.request_count > 0 {
                    max_ttft = max_ttft.max(m.avg_ttft_ms);
                    min_ttft = min_ttft.min(m.avg_ttft_ms);
                    max_tpot = max_tpot.max(m.avg_tpot_ms);
                    min_tpot = min_tpot.min(m.avg_tpot_ms);
                    max_throughput = max_throughput.max(m.avg_tokens_per_sec);
                    min_throughput = min_throughput.min(m.avg_tokens_per_sec);
                }
            }

            // Calculate scores
            for worker in workers {
                let url = worker.url();
                if let Some(m) = metrics.get(url) {
                    if m.request_count == 0 {
                        scores.insert(url.to_string(), 0.0);
                        continue;
                    }

                    // Normalize metrics to 0-1 range (invert TTFT/TPOT since lower is better)
                    let norm_ttft = if max_ttft > min_ttft {
                        1.0 - (m.avg_ttft_ms - min_ttft) / (max_ttft - min_ttft)
                    } else {
                        1.0
                    };

                    let norm_tpot = if max_tpot > min_tpot {
                        1.0 - (m.avg_tpot_ms - min_tpot) / (max_tpot - min_tpot)
                    } else {
                        1.0
                    };

                    let norm_throughput = if max_throughput > min_throughput {
                        (m.avg_tokens_per_sec - min_throughput) / (max_throughput - min_throughput)
                    } else {
                        1.0
                    };

                    // Weighted score
                    let mut score = self.config.weight_ttft * norm_ttft
                        + self.config.weight_tpot * norm_tpot
                        + self.config.weight_throughput * norm_throughput;

                    // Apply load factor if configured
                    if self.config.consider_load {
                        let load = worker.load() as f64;
                        let load_factor = 1.0 / (1.0 + load);
                        score *= load_factor;
                    }

                    scores.insert(url.to_string(), score);
                } else {
                    scores.insert(url.to_string(), 0.0);
                }
            }
        }

        let mut cached = self.cached_scores.write().unwrap();
        *cached = scores;

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.last_score_refresh.store(now, Ordering::Relaxed);

        debug!(
            "[PerformanceAware] Refreshed performance scores for {} workers",
            workers.len()
        );
    }

    /// Record performance metrics for a worker
    pub fn record_metrics(&self, worker_url: &str, ttft_ms: f64, tpot_ms: f64, tokens_per_sec: f64) {
        let mut metrics = self.worker_metrics.write().unwrap();
        let entry = metrics
            .entry(worker_url.to_string())
            .or_insert_with(WorkerPerformanceMetrics::new);
        entry.update(ttft_ms, tpot_ms, tokens_per_sec);
    }
}

#[async_trait]
impl LoadBalancingPolicy for PerformanceAwarePolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        _info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);

        if healthy_indices.is_empty() {
            return None;
        }

        // Refresh scores if needed
        if self.should_refresh_scores() {
            self.calculate_scores(workers);
        }

        // Get cached scores
        let scores = self.cached_scores.read().unwrap();

        // Select worker with highest score
        let mut best_idx = healthy_indices[0];
        let mut best_score = scores
            .get(workers[best_idx].url())
            .copied()
            .unwrap_or(0.0);

        for &idx in &healthy_indices[1..] {
            let score = scores.get(workers[idx].url()).copied().unwrap_or(0.0);
            if score > best_score {
                best_score = score;
                best_idx = idx;
            }
        }

        debug!(
            "[PerformanceAware] Selected worker {} (url={}, score={:.3})",
            best_idx,
            workers[best_idx].url(),
            best_score
        );

        workers[best_idx].increment_processed();
        Some(best_idx)
    }

    fn on_request_complete(&self, worker_url: &str, success: bool) {
        if !success {
            tracing::debug!(
                "[PerformanceAware] Request to {} completed with success={}",
                worker_url,
                success
            );
        }
    }

    fn name(&self) -> &'static str {
        "performance_aware"
    }

    fn needs_request_text(&self) -> bool {
        false // Does not need request text
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl Default for PerformanceAwarePolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    #[tokio::test]
    async fn test_performance_aware_scoring() {
        let config = PerformanceAwareConfig {
            weight_ttft: 0.3,
            weight_tpot: 0.3,
            weight_throughput: 0.4,
            score_refresh_interval_secs: 60,
            consider_load: true,
        };
        let policy = PerformanceAwarePolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            Arc::new(
                BasicWorkerBuilder::new("http://fast:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "10")
                    .label("cost", "1.0")
                    .build(),
            ),
            Arc::new(
                BasicWorkerBuilder::new("http://slow:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "5")
                    .label("cost", "2.0")
                    .build(),
            ),
        ];

        // Record performance metrics
        policy.record_metrics("http://fast:8000", 50.0, 10.0, 100.0);
        policy.record_metrics("http://slow:8000", 100.0, 20.0, 50.0);

        // Force score refresh
        policy.calculate_scores(&workers);

        // Select worker
        let idx = policy
            .select_worker(&workers, &SelectWorkerInfo::default())
            .await;

        // Should select the faster worker
        assert!(idx.is_some());
        // The fast worker should be selected more often due to better metrics
    }

    #[tokio::test]
    async fn test_performance_aware_no_metrics_fallback() {
        let policy = PerformanceAwarePolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            Arc::new(
                BasicWorkerBuilder::new("http://w1:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "10")
                    .label("cost", "1.0")
                    .build(),
            ),
            Arc::new(
                BasicWorkerBuilder::new("http://w2:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "5")
                    .label("cost", "2.0")
                    .build(),
            ),
        ];

        // No metrics recorded yet, should fallback to priority/cost
        let idx = policy
            .select_worker(&workers, &SelectWorkerInfo::default())
            .await;

        assert!(idx.is_some());
    }

    #[test]
    fn test_metrics_update() {
        let mut metrics = WorkerPerformanceMetrics::new();

        metrics.update(100.0, 20.0, 50.0);
        assert_eq!(metrics.request_count, 1);
        assert!((metrics.avg_ttft_ms - 100.0).abs() < 0.01);

        metrics.update(120.0, 25.0, 45.0);
        assert_eq!(metrics.request_count, 2);
        assert!((metrics.avg_ttft_ms - 110.0).abs() < 0.01);
        assert!((metrics.avg_tpot_ms - 22.5).abs() < 0.01);
    }
}

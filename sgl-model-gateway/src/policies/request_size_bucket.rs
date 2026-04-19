//! Request Size Bucket Load Balancing Policy
//!
//! This policy classifies requests by their input length (character count) and routes them
//! to different workers based on bucket boundaries. It's designed for heterogeneous GPU
//! scenarios where different workers may be optimized for different request sizes.
#![allow(dead_code)]
//!
//! ## Strategy Details
//!
//! Buckets:
//! - **Short** (< short_threshold): Route to workers optimized for quick responses
//! - **Medium** (short_threshold..medium_threshold): Route to balanced workers
//! - **Long** (>= medium_threshold): Route to workers with large memory capacity
//!
//! This policy is particularly useful when:
//! - Some GPUs have low latency but limited memory (handle short requests)
//! - Some GPUs have high memory capacity but slower compute (handle long requests)
//! - You want to isolate request types to prevent resource contention
//!
//! ## Configuration
//!
//! - `short_threshold`: Boundary between short and medium requests (default: 100 chars)
//! - `medium_threshold`: Boundary between medium and long requests (default: 500 chars)
//! - `track_load_per_bucket`: Whether to track load separately per bucket (default: true)

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tracing::debug;

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

/// Configuration for request size bucket policy
#[derive(Debug, Clone)]
pub struct RequestSizeBucketConfig {
    /// Threshold for short requests (chars < this value are "short")
    pub short_threshold: usize,
    /// Threshold for medium requests (chars < this value are "medium", >= are "long")
    pub medium_threshold: usize,
    /// Whether to track load separately per bucket
    pub track_load_per_bucket: bool,
}

impl Default for RequestSizeBucketConfig {
    fn default() -> Self {
        Self {
            short_threshold: 100,
            medium_threshold: 500,
            track_load_per_bucket: true,
        }
    }
}

/// Request size category
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RequestSizeCategory {
    Short,
    Medium,
    Long,
}

impl std::fmt::Display for RequestSizeCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RequestSizeCategory::Short => write!(f, "short"),
            RequestSizeCategory::Medium => write!(f, "medium"),
            RequestSizeCategory::Long => write!(f, "long"),
        }
    }
}

/// Per-bucket load tracking
#[derive(Debug)]
struct BucketLoadTracker {
    /// Current load per worker (atomic for thread-safe updates)
    worker_loads: HashMap<usize, Arc<AtomicUsize>>,
    /// Assignment preference: which workers are preferred for this bucket
    preferred_workers: Vec<usize>,
}

impl BucketLoadTracker {
    fn new() -> Self {
        Self {
            worker_loads: HashMap::new(),
            preferred_workers: Vec::new(),
        }
    }

    fn increment_load(&self, worker_idx: usize) {
        if let Some(load) = self.worker_loads.get(&worker_idx) {
            load.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn decrement_load(&self, worker_idx: usize) {
        if let Some(load) = self.worker_loads.get(&worker_idx) {
            load.fetch_sub(1, Ordering::Relaxed);
        }
    }

    fn get_load(&self, worker_idx: usize) -> usize {
        self.worker_loads
            .get(&worker_idx)
            .map(|load| load.load(Ordering::Relaxed))
            .unwrap_or(0)
    }
}

/// Request size bucket load balancing policy
#[derive(Debug)]
pub struct RequestSizeBucketPolicy {
    config: RequestSizeBucketConfig,
    /// Load tracking per bucket (Short, Medium, Long)
    bucket_loads: Arc<Mutex<HashMap<RequestSizeCategory, BucketLoadTracker>>>,
    /// Worker category assignments (which workers handle which bucket types)
    worker_assignments: Arc<Mutex<HashMap<usize, RequestSizeCategory>>>,
}

impl RequestSizeBucketPolicy {
    pub fn new() -> Self {
        Self::with_config(RequestSizeBucketConfig::default())
    }

    pub fn with_config(config: RequestSizeBucketConfig) -> Self {
        let mut bucket_loads = HashMap::new();
        bucket_loads.insert(RequestSizeCategory::Short, BucketLoadTracker::new());
        bucket_loads.insert(RequestSizeCategory::Medium, BucketLoadTracker::new());
        bucket_loads.insert(RequestSizeCategory::Long, BucketLoadTracker::new());

        Self {
            config,
            bucket_loads: Arc::new(Mutex::new(bucket_loads)),
            worker_assignments: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Classify a request by its length
    fn classify_request(&self, char_count: usize) -> RequestSizeCategory {
        if char_count < self.config.short_threshold {
            RequestSizeCategory::Short
        } else if char_count < self.config.medium_threshold {
            RequestSizeCategory::Medium
        } else {
            RequestSizeCategory::Long
        }
    }

    /// Initialize worker assignments based on their priority/cost metadata
    /// Workers with high priority and low cost are assigned to Short bucket
    /// Workers with low priority and high cost are assigned to Long bucket
    fn initialize_worker_assignments(&self, workers: &[Arc<dyn Worker>]) {
        let mut assignments = self.worker_assignments.lock().unwrap();
        assignments.clear();

        if workers.is_empty() {
            return;
        }

        // Sort workers by priority (descending) and cost (ascending)
        let mut worker_scores: Vec<(usize, f32)> = workers
            .iter()
            .enumerate()
            .map(|(idx, w)| {
                let priority = w.priority();
                let cost = w.cost();
                // Score = priority / cost (higher is better for short requests)
                let score = if cost > 0.0 {
                    priority as f32 / cost
                } else {
                    0.0
                };
                (idx, score)
            })
            .collect();

        worker_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let num_workers = worker_scores.len();
        // Divide workers into three groups based on score
        let third = num_workers / 3;

        for (i, (idx, _score)) in worker_scores.iter().enumerate() {
            let category = if i < third {
                RequestSizeCategory::Short // Best workers for short requests
            } else if i < 2 * third {
                RequestSizeCategory::Medium // Middle workers
            } else {
                RequestSizeCategory::Long // Remaining workers for long requests
            };
            assignments.insert(*idx, category);
        }

        debug!(
            "RequestSizeBucket: Initialized {} workers across 3 buckets",
            num_workers
        );
    }

    /// Select worker from a specific bucket using least-loaded strategy
    fn select_from_bucket(
        &self,
        workers: &[Arc<dyn Worker>],
        healthy_indices: &[usize],
        category: RequestSizeCategory,
    ) -> Option<usize> {
        if healthy_indices.is_empty() {
            return None;
        }

        // Find healthy workers assigned to this bucket
        let assigned = healthy_indices
            .iter()
            .filter(|&&idx| {
                let assignments = self.worker_assignments.lock().unwrap();
                assignments
                    .get(&idx)
                    .map(|cat| *cat == category)
                    .unwrap_or(false)
            })
            .copied()
            .collect::<Vec<_>>();

        // If no workers are assigned to this bucket, fall back to all healthy workers
        let candidates = if assigned.is_empty() {
            debug!(
                "No workers assigned to {} bucket, using all healthy workers",
                category
            );
            healthy_indices.to_vec()
        } else {
            assigned
        };

        // Select least-loaded worker from candidates
        if self.config.track_load_per_bucket {
            let bucket_loads = self.bucket_loads.lock().unwrap();
            if let Some(tracker) = bucket_loads.get(&category) {
                let selected = candidates
                    .iter()
                    .min_by_key(|&&idx| tracker.get_load(idx))
                    .copied();

                if let Some(idx) = selected {
                    tracker.increment_load(idx);
                    workers[idx].increment_processed();
                }

                return selected;
            }
        }

        // Fallback to simple least-loaded
        let selected = candidates
            .iter()
            .min_by_key(|&&idx| workers[idx].load())
            .copied();

        if let Some(idx) = selected {
            workers[idx].increment_processed();
        }

        selected
    }
}

#[async_trait]
impl LoadBalancingPolicy for RequestSizeBucketPolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);

        if healthy_indices.is_empty() {
            return None;
        }

        // Initialize worker assignments if not done yet
        {
            let assignments = self.worker_assignments.lock().unwrap();
            if assignments.is_empty() {
                drop(assignments);
                self.initialize_worker_assignments(workers);
            }
        }

        // Get request length
        let char_count = match info.request_text {
            Some(text) => text.chars().count(),
            None => 0,
        };

        // Classify request
        let category = self.classify_request(char_count);

        debug!(
            "[RequestSizeBucket] Request classified as {} ({} chars)",
            category, char_count
        );

        // Select worker from appropriate bucket
        self.select_from_bucket(workers, &healthy_indices, category)
    }

    fn on_request_complete(&self, worker_url: &str, success: bool) {
        if !success {
            tracing::debug!(
                "[RequestSizeBucket] Request to {} completed with success={}",
                worker_url,
                success
            );
        }
        // Could update bucket load tracking here if needed
    }

    fn name(&self) -> &'static str {
        "request_size_bucket"
    }

    fn needs_request_text(&self) -> bool {
        true // Needs request text to classify by length
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl Default for RequestSizeBucketPolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    #[tokio::test]
    async fn test_request_classification() {
        let config = RequestSizeBucketConfig {
            short_threshold: 100,
            medium_threshold: 500,
            track_load_per_bucket: true,
        };
        let policy = RequestSizeBucketPolicy::with_config(config);

        assert_eq!(policy.classify_request(50), RequestSizeCategory::Short);
        assert_eq!(policy.classify_request(99), RequestSizeCategory::Short);
        assert_eq!(policy.classify_request(100), RequestSizeCategory::Medium);
        assert_eq!(policy.classify_request(499), RequestSizeCategory::Medium);
        assert_eq!(policy.classify_request(500), RequestSizeCategory::Long);
        assert_eq!(policy.classify_request(1000), RequestSizeCategory::Long);
    }

    #[tokio::test]
    async fn test_worker_assignment() {
        let policy = RequestSizeBucketPolicy::new();

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
            Arc::new(
                BasicWorkerBuilder::new("http://w3:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "1")
                    .label("cost", "5.0")
                    .build(),
            ),
        ];

        policy.initialize_worker_assignments(&workers);

        let assignments = policy.worker_assignments.lock().unwrap();
        assert_eq!(assignments.len(), 3);

        // Worker 0 (score=10.0) should be assigned to Short
        assert_eq!(
            assignments.get(&0),
            Some(&RequestSizeCategory::Short)
        );
        // Worker 2 (score=0.2) should be assigned to Long
        assert_eq!(
            assignments.get(&2),
            Some(&RequestSizeCategory::Long)
        );
    }

    #[tokio::test]
    async fn test_routing_by_request_size() {
        let config = RequestSizeBucketConfig {
            short_threshold: 100,
            medium_threshold: 500,
            track_load_per_bucket: false, // Disable for simpler testing
        };
        let policy = RequestSizeBucketPolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            Arc::new(
                BasicWorkerBuilder::new("http://w1:8000")
                    .worker_type(WorkerType::Regular)
                    .build(),
            ),
            Arc::new(
                BasicWorkerBuilder::new("http://w2:8000")
                    .worker_type(WorkerType::Regular)
                    .build(),
            ),
        ];

        // Initialize assignments
        policy.initialize_worker_assignments(&workers);

        // Short request
        let short_idx = policy
            .select_worker(
                &workers,
                &SelectWorkerInfo {
                    request_text: Some("short"),
                    ..Default::default()
                },
            )
            .await;
        assert!(short_idx.is_some());

        // Long request
        let long_idx = policy
            .select_worker(
                &workers,
                &SelectWorkerInfo {
                    request_text: Some(&"a".repeat(600)),
                    ..Default::default()
                },
            )
            .await;
        assert!(long_idx.is_some());
    }
}

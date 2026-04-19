//! Request Classification Load Balancing Policy
//!
//! This policy classifies requests based on multiple characteristics (not just length)
//! and routes them to workers optimized for that request type. It considers:
//! - Prompt length (short/medium/long)
//! - Expected generation length (based on max_tokens parameter)
//! - Request type (compute-intensive vs memory-intensive)
//!
//! ## Strategy Details
//!
//! Classification dimensions:
//! 1. **Input Length**: Short (<100), Medium (100-500), Long (>500 chars)
//! 2. **Output Length**: Small (<100 tokens), Medium (100-500), Large (>500 tokens)
//! 3. **Compute Pattern**:
//!    - Compute-intensive: Short input + Long output (e.g., creative writing)
//!    - Memory-intensive: Long input + Short output (e.g., summarization)
//!    - Balanced: Medium input + Medium output
//!
//! Worker assignment strategy:
//! - High-end GPUs (fast compute) → Compute-intensive requests
//! - High-memory GPUs → Memory-intensive requests
//! - Balanced GPUs → Balanced requests
//!
//! ## Configuration
//!
//! The policy can extract request characteristics from:
//! - Request text length
//! - `max_tokens` parameter from headers
//! - Custom classification headers (X-SM-Request-Type)

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use async_trait::async_trait;
use tracing::debug;

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

/// Configuration for request classification policy
#[derive(Debug, Clone)]
pub struct RequestClassificationConfig {
    /// Threshold for short input (chars)
    pub short_input_threshold: usize,
    /// Threshold for medium input (chars)
    pub medium_input_threshold: usize,
    /// Threshold for small output (tokens)
    pub small_output_threshold: usize,
    /// Threshold for medium output (tokens)
    pub medium_output_threshold: usize,
    /// Whether to use worker priority/cost for automatic assignment
    pub auto_assign_workers: bool,
}

impl Default for RequestClassificationConfig {
    fn default() -> Self {
        Self {
            short_input_threshold: 100,
            medium_input_threshold: 500,
            small_output_threshold: 100,
            medium_output_threshold: 500,
            auto_assign_workers: true,
        }
    }
}

/// Request classification result
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RequestType {
    /// Short input, long output - compute intensive
    ComputeIntensive,
    /// Long input, short output - memory intensive
    MemoryIntensive,
    /// Medium input, medium output - balanced
    Balanced,
    /// Unknown or unclassified
    Unknown,
}

impl std::fmt::Display for RequestType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RequestType::ComputeIntensive => write!(f, "compute_intensive"),
            RequestType::MemoryIntensive => write!(f, "memory_intensive"),
            RequestType::Balanced => write!(f, "balanced"),
            RequestType::Unknown => write!(f, "unknown"),
        }
    }
}

/// Worker classification
#[derive(Debug, Clone)]
struct WorkerProfile {
    /// Worker URL
    url: String,
    /// Priority (higher = better performance)
    priority: u32,
    /// Cost (higher = more expensive, often means more memory)
    cost: f32,
    /// Current load
    load: usize,
}

/// Request classification load balancing policy
#[derive(Debug)]
pub struct RequestClassificationPolicy {
    config: RequestClassificationConfig,
    /// Worker profiles for classification
    worker_profiles: Arc<RwLock<HashMap<String, WorkerProfile>>>,
    /// Request type to worker assignment mapping
    type_assignments: Arc<RwLock<HashMap<RequestType, Vec<String>>>>,
}

impl RequestClassificationPolicy {
    pub fn new() -> Self {
        Self::with_config(RequestClassificationConfig::default())
    }

    pub fn with_config(config: RequestClassificationConfig) -> Self {
        Self {
            config,
            worker_profiles: Arc::new(RwLock::new(HashMap::new())),
            type_assignments: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Classify request based on input/output characteristics
    fn classify_request(&self, info: &SelectWorkerInfo<'_>) -> RequestType {
        // Get input length
        let input_length = match info.request_text {
            Some(text) => text.chars().count(),
            None => 0,
        };

        // Get expected output length from headers
        let output_length = self.extract_max_tokens(info);

        // Classify input
        let input_category = if input_length < self.config.short_input_threshold {
            "short"
        } else if input_length < self.config.medium_input_threshold {
            "medium"
        } else {
            "long"
        };

        // Classify output
        let output_category = if output_length < self.config.small_output_threshold {
            "small"
        } else if output_length < self.config.medium_output_threshold {
            "medium"
        } else {
            "large"
        };

        debug!(
            "[RequestClassification] Input: {} ({} chars), Output: {} ({} tokens)",
            input_category, input_length, output_category, output_length
        );

        // Determine request type
        if input_category == "short" && (output_category == "medium" || output_category == "large") {
            RequestType::ComputeIntensive
        } else if input_category == "long"
            && (output_category == "small" || output_category == "medium")
        {
            RequestType::MemoryIntensive
        } else if input_category == "medium" && output_category == "medium" {
            RequestType::Balanced
        } else {
            // Default classification based on dominant characteristic
            if input_length > 500 {
                RequestType::MemoryIntensive
            } else if output_length > 200 {
                RequestType::ComputeIntensive
            } else {
                RequestType::Balanced
            }
        }
    }

    /// Extract max_tokens from headers or return default
    fn extract_max_tokens(&self, info: &SelectWorkerInfo<'_>) -> usize {
        // Try to extract from headers
        if let Some(headers) = info.headers {
            // Check for custom header first
            if let Some(max_tokens_str) = headers.get("x-sm-max-tokens") {
                if let Ok(tokens) = max_tokens_str.to_str().unwrap_or("").parse::<usize>() {
                    return tokens;
                }
            }

            // Check for standard OpenAI header
            if let Some(max_tokens_str) = headers.get("x-max-tokens") {
                if let Ok(tokens) = max_tokens_str.to_str().unwrap_or("").parse::<usize>() {
                    return tokens;
                }
            }
        }

        // Default estimate
        200
    }

    /// Initialize worker profiles and assignments
    fn initialize_workers(&self, workers: &[Arc<dyn Worker>]) {
        if !self.config.auto_assign_workers {
            return;
        }

        let mut profiles = HashMap::new();
        let mut compute_workers = Vec::new();
        let mut memory_workers = Vec::new();
        let mut balanced_workers = Vec::new();

        for worker in workers {
            let url = worker.url().to_string();
            let priority = worker.priority();
            let cost = worker.cost();

            profiles.insert(
                url.clone(),
                WorkerProfile {
                    url: url.clone(),
                    priority,
                    cost,
                    load: worker.load(),
                },
            );

            // Classify worker based on priority/cost ratio
            // High priority + low cost = compute-optimized
            // Low priority + high cost = memory-optimized
            let score = if cost > 0.0 {
                priority as f32 / cost
            } else {
                0.0
            };

            if score > 5.0 {
                compute_workers.push(url);
            } else if score < 1.0 {
                memory_workers.push(url);
            } else {
                balanced_workers.push(url);
            }
        }

        let mut assignments = HashMap::new();
        assignments.insert(RequestType::ComputeIntensive, compute_workers);
        assignments.insert(RequestType::MemoryIntensive, memory_workers);
        assignments.insert(RequestType::Balanced, balanced_workers);

        let mut worker_profiles_lock = self.worker_profiles.write().unwrap();
        *worker_profiles_lock = profiles;

        let mut type_assignments_lock = self.type_assignments.write().unwrap();
        *type_assignments_lock = assignments;

        debug!(
            "[RequestClassification] Initialized workers: {} compute, {} memory, {} balanced",
            self.type_assignments
                .read()
                .unwrap()
                .get(&RequestType::ComputeIntensive)
                .map_or(0, |v| v.len()),
            self.type_assignments
                .read()
                .unwrap()
                .get(&RequestType::MemoryIntensive)
                .map_or(0, |v| v.len()),
            self.type_assignments
                .read()
                .unwrap()
                .get(&RequestType::Balanced)
                .map_or(0, |v| v.len())
        );
    }

    /// Select worker for a specific request type
    fn select_worker_for_type(
        &self,
        workers: &[Arc<dyn Worker>],
        healthy_indices: &[usize],
        request_type: RequestType,
    ) -> Option<usize> {
        if healthy_indices.is_empty() {
            return None;
        }

        // Get workers assigned to this request type
        let type_assignments = self.type_assignments.read().unwrap();
        let assigned_workers = type_assignments.get(&request_type).cloned();

        let assigned_workers = match assigned_workers {
            Some(workers) if !workers.is_empty() => workers,
            _ => {
                debug!(
                    "[RequestClassification] No workers assigned to {:?}, using all healthy workers",
                    request_type
                );
                return healthy_indices
                    .iter()
                    .min_by_key(|&&idx| workers[idx].load())
                    .copied()
                    .map(|idx| {
                        workers[idx].increment_processed();
                        idx
                    });
            }
        };

        // Find healthy workers from assigned list
        let healthy_assigned: Vec<usize> = healthy_indices
            .iter()
            .filter(|&&idx| {
                let url = workers[idx].url();
                assigned_workers.contains(&url.to_string())
            })
            .copied()
            .collect();

        if healthy_assigned.is_empty() {
            debug!(
                "[RequestClassification] No healthy workers for {:?}, falling back to any healthy worker",
                request_type
            );
            return healthy_indices
                .iter()
                .min_by_key(|&&idx| workers[idx].load())
                .copied()
                .map(|idx| {
                    workers[idx].increment_processed();
                    idx
                });
        }

        // Select least-loaded worker from assigned healthy workers
        let selected = healthy_assigned
            .iter()
            .min_by_key(|&&idx| workers[idx].load())
            .copied();

        if let Some(idx) = selected {
            debug!(
                "[RequestClassification] Selected worker {} ({:?}) for {:?} request",
                idx,
                workers[idx].url(),
                request_type
            );
            workers[idx].increment_processed();
        }

        selected
    }
}

#[async_trait]
impl LoadBalancingPolicy for RequestClassificationPolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);

        if healthy_indices.is_empty() {
            return None;
        }

        // Initialize workers if not done yet
        {
            let profiles = self.worker_profiles.read().unwrap();
            if profiles.is_empty() {
                drop(profiles);
                self.initialize_workers(workers);
            }
        }

        // Classify request
        let request_type = self.classify_request(info);

        debug!(
            "[RequestClassification] Request classified as {:?}",
            request_type
        );

        // Select appropriate worker
        self.select_worker_for_type(workers, &healthy_indices, request_type)
    }

    fn on_request_complete(&self, worker_url: &str, success: bool) {
        if !success {
            tracing::debug!(
                "[RequestClassification] Request to {} completed with success={}",
                worker_url,
                success
            );
        }
    }

    fn name(&self) -> &'static str {
        "request_classification"
    }

    fn needs_request_text(&self) -> bool {
        true // Needs request text for classification
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl Default for RequestClassificationPolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    #[tokio::test]
    async fn test_request_classification_compute_intensive() {
        let config = RequestClassificationConfig {
            short_input_threshold: 100,
            medium_input_threshold: 500,
            small_output_threshold: 100,
            medium_output_threshold: 500,
            auto_assign_workers: true,
        };
        let policy = RequestClassificationPolicy::with_config(config);

        // Short input, large output = compute intensive
        let info = SelectWorkerInfo {
            request_text: Some("Hello"),
            ..Default::default()
        };

        let request_type = policy.classify_request(&info);
        assert_eq!(request_type, RequestType::ComputeIntensive);
    }

    #[tokio::test]
    async fn test_request_classification_memory_intensive() {
        let config = RequestClassificationConfig {
            short_input_threshold: 100,
            medium_input_threshold: 500,
            small_output_threshold: 100,
            medium_output_threshold: 500,
            auto_assign_workers: true,
        };
        let policy = RequestClassificationPolicy::with_config(config);

        // Long input, small output = memory intensive
        let long_text = "a".repeat(600);
        let info = SelectWorkerInfo {
            request_text: Some(&long_text),
            ..Default::default()
        };

        let request_type = policy.classify_request(&info);
        assert_eq!(request_type, RequestType::MemoryIntensive);
    }

    #[tokio::test]
    async fn test_worker_assignment() {
        let policy = RequestClassificationPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            Arc::new(
                BasicWorkerBuilder::new("http://compute:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "10")
                    .label("cost", "1.0")
                    .build(),
            ),
            Arc::new(
                BasicWorkerBuilder::new("http://memory:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "2")
                    .label("cost", "5.0")
                    .build(),
            ),
            Arc::new(
                BasicWorkerBuilder::new("http://balanced:8000")
                    .worker_type(WorkerType::Regular)
                    .label("priority", "5")
                    .label("cost", "2.0")
                    .build(),
            ),
        ];

        policy.initialize_workers(&workers);

        let assignments = policy.type_assignments.read().unwrap();
        // Compute worker should be in compute_intensive
        assert!(assignments
            .get(&RequestType::ComputeIntensive)
            .unwrap()
            .contains(&"http://compute:8000".to_string()));

        // Memory worker should be in memory_intensive
        assert!(assignments
            .get(&RequestType::MemoryIntensive)
            .unwrap()
            .contains(&"http://memory:8000".to_string()));
    }

    #[tokio::test]
    async fn test_routing_with_classification() {
        let policy = RequestClassificationPolicy::new();

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

        // Short request
        let short_idx = policy
            .select_worker(
                &workers,
                &SelectWorkerInfo {
                    request_text: Some("Hello world"),
                    ..Default::default()
                },
            )
            .await;
        assert!(short_idx.is_some());

        // Long request
        let long_text = "a".repeat(1000);
        let long_idx = policy
            .select_worker(
                &workers,
                &SelectWorkerInfo {
                    request_text: Some(&long_text),
                    ..Default::default()
                },
            )
            .await;
        assert!(long_idx.is_some());
    }
}

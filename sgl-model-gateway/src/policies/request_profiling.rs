//! Request Profiling Policy for heterogeneous GPU scheduling
//!
//! This policy classifies requests by multiple characteristics (input length, output length,
//! streaming mode) and routes them to pre-configured worker groups with affinity binding.
//!
//! ## Strategy Details
//!
//! Request classification dimensions:
//! - **Input length**: Short / Medium / Long context
//! - **Output length**: Derived from `max_tokens` parameter in request body
//! - **Streaming**: Whether the request uses streaming mode
//!
//! Worker binding:
//! - Workers are assigned to "profiles" (buckets) via labels (`profile` key)
//! - Requests are matched to the best profile based on classification rules
//! - Within a profile, least-loaded selection is used
//! - Fallback to any healthy worker if no profile match
//!
//! ## Configuration
//!
//! - `short_input_threshold`: Boundary between short and medium input (default: 500 chars)
//! - `long_input_threshold`: Boundary between medium and long input (default: 4000 chars)
//! - `large_output_threshold`: Threshold for "large output" requests (default: 1024 tokens)
//! - `profiles`: Named worker profiles with routing rules
//!
//! ## Worker Labels
//!
//! Workers declare their profile via labels:
//! ```text
//! --worker-label profile=short      # Handles short/quick requests
//! --worker-label profile=long       # Handles long context requests
//! --worker-label profile=default    # General purpose
//! ```
//!
//! If no `profile` label is set, workers are assigned to "default" profile.

#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::RwLock;
use tracing::debug;

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

// ─── Configuration ───────────────────────────────────────────────────────────

/// Configuration for request profiling policy
#[derive(Debug, Clone)]
pub struct RequestProfilingConfig {
    /// Threshold for short input in characters (< this = short)
    pub short_input_threshold: usize,
    /// Threshold for long input in characters (>= this = long)
    pub long_input_threshold: usize,
    /// Threshold for large output in tokens (>= this = large output)
    pub large_output_threshold: usize,
    /// Named routing profiles: profile_name -> matching rules
    pub profiles: Vec<ProfileRule>,
}

impl Default for RequestProfilingConfig {
    fn default() -> Self {
        Self {
            short_input_threshold: 500,
            long_input_threshold: 4000,
            large_output_threshold: 1024,
            profiles: vec![
                ProfileRule {
                    name: "short".to_string(),
                    match_input: Some(InputCategory::Short),
                    match_output: None,
                    match_stream: None,
                    priority: 10,
                },
                ProfileRule {
                    name: "long".to_string(),
                    match_input: Some(InputCategory::Long),
                    match_output: None,
                    match_stream: None,
                    priority: 10,
                },
                ProfileRule {
                    name: "large_output".to_string(),
                    match_input: None,
                    match_output: Some(OutputCategory::Large),
                    match_stream: None,
                    priority: 5,
                },
                ProfileRule {
                    name: "default".to_string(),
                    match_input: None,
                    match_output: None,
                    match_stream: None,
                    priority: 0, // Lowest priority = catch-all
                },
            ],
        }
    }
}

/// A routing profile rule: defines when a request matches a profile
#[derive(Debug, Clone)]
pub struct ProfileRule {
    /// Profile name (must match worker label `profile=<name>`)
    pub name: String,
    /// Match on input category (None = any)
    pub match_input: Option<InputCategory>,
    /// Match on output category (None = any)
    pub match_output: Option<OutputCategory>,
    /// Match on streaming mode (None = any)
    pub match_stream: Option<bool>,
    /// Rule priority (higher = checked first; equal priority = first match wins)
    pub priority: u32,
}

// ─── Request Classification ──────────────────────────────────────────────────

/// Input length category
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum InputCategory {
    Short,
    Medium,
    Long,
}

impl std::fmt::Display for InputCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputCategory::Short => write!(f, "short"),
            InputCategory::Medium => write!(f, "medium"),
            InputCategory::Long => write!(f, "long"),
        }
    }
}

/// Output length category
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OutputCategory {
    Small,
    Medium,
    Large,
}

impl std::fmt::Display for OutputCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OutputCategory::Small => write!(f, "small"),
            OutputCategory::Medium => write!(f, "medium"),
            OutputCategory::Large => write!(f, "large"),
        }
    }
}

/// Classified request characteristics
#[derive(Debug, Clone)]
struct RequestProfile {
    input_category: InputCategory,
    output_category: OutputCategory,
    is_stream: bool,
}

// ─── Policy Implementation ───────────────────────────────────────────────────

/// Worker profile cache: maps profile_name -> list of worker indices
#[derive(Debug, Default)]
struct ProfileWorkerCache {
    /// profile_name -> worker indices (updated on worker list change)
    map: HashMap<String, Vec<usize>>,
    /// Number of workers when cache was built (invalidation check)
    worker_count: usize,
}

/// Request Profiling Policy
///
/// Routes requests to worker groups based on request characteristics.
/// Workers declare their affinity profile via labels.
#[derive(Debug)]
pub struct RequestProfilingPolicy {
    config: RequestProfilingConfig,
    /// Sorted rules (by priority descending)
    sorted_rules: Vec<ProfileRule>,
    /// Cached worker-to-profile mapping
    profile_cache: RwLock<ProfileWorkerCache>,
}

impl RequestProfilingPolicy {
    pub fn new() -> Self {
        Self::with_config(RequestProfilingConfig::default())
    }

    pub fn with_config(config: RequestProfilingConfig) -> Self {
        let mut sorted_rules = config.profiles.clone();
        sorted_rules.sort_by(|a, b| b.priority.cmp(&a.priority));

        Self {
            config,
            sorted_rules,
            profile_cache: RwLock::new(ProfileWorkerCache::default()),
        }
    }

    /// Classify a request based on its text content
    fn classify_request(&self, info: &SelectWorkerInfo<'_>) -> RequestProfile {
        let request_text = info.request_text.unwrap_or("");

        // 1. Input length classification
        let char_count = request_text.len(); // Use byte length for performance (close enough for ASCII-heavy LLM prompts)
        let input_category = if char_count < self.config.short_input_threshold {
            InputCategory::Short
        } else if char_count >= self.config.long_input_threshold {
            InputCategory::Long
        } else {
            InputCategory::Medium
        };

        // 2. Output length classification (extract max_tokens from request body)
        let max_tokens = Self::extract_max_tokens(request_text);
        let output_category = if max_tokens >= self.config.large_output_threshold {
            OutputCategory::Large
        } else if max_tokens >= self.config.large_output_threshold / 4 {
            OutputCategory::Medium
        } else {
            OutputCategory::Small
        };

        // 3. Streaming detection
        let is_stream = Self::extract_stream(request_text);

        RequestProfile {
            input_category,
            output_category,
            is_stream,
        }
    }

    /// Extract `max_tokens` from request JSON text (fast path: substring search)
    fn extract_max_tokens(text: &str) -> usize {
        // Fast path: look for "max_tokens" pattern in raw text
        // This avoids full JSON parse for every request
        if let Some(pos) = text.find("\"max_tokens\"") {
            let after = &text[pos + 12..]; // skip past "max_tokens"
            // Find the colon then the number
            if let Some(colon_pos) = after.find(':') {
                let after_colon = after[colon_pos + 1..].trim_start();
                // Parse the number
                let num_str: String = after_colon
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                if let Ok(val) = num_str.parse::<usize>() {
                    return val;
                }
            }
        }
        // Also check max_completion_tokens (OpenAI newer API)
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
        // Default: assume medium output if not specified
        512
    }

    /// Extract `stream` field from request text
    fn extract_stream(text: &str) -> bool {
        // Fast path: look for "stream": true pattern
        if let Some(pos) = text.find("\"stream\"") {
            let after = &text[pos + 8..];
            if let Some(colon_pos) = after.find(':') {
                let after_colon = after[colon_pos + 1..].trim_start();
                return after_colon.starts_with("true");
            }
        }
        false
    }

    /// Match a classified request to the best profile name
    fn match_profile(&self, profile: &RequestProfile) -> &str {
        for rule in &self.sorted_rules {
            let input_match = rule
                .match_input
                .map_or(true, |cat| cat == profile.input_category);
            let output_match = rule
                .match_output
                .map_or(true, |cat| cat == profile.output_category);
            let stream_match = rule.match_stream.map_or(true, |s| s == profile.is_stream);

            if input_match && output_match && stream_match {
                return &rule.name;
            }
        }
        "default"
    }

    /// Build or refresh the profile -> worker index cache
    fn refresh_profile_cache(&self, workers: &[Arc<dyn Worker>]) {
        let mut cache = self.profile_cache.write();
        if cache.worker_count == workers.len() && !cache.map.is_empty() {
            return; // Cache is still valid
        }

        let mut map: HashMap<String, Vec<usize>> = HashMap::new();

        for (idx, worker) in workers.iter().enumerate() {
            if !worker.is_healthy() || !worker.circuit_breaker().can_execute() {
                continue;
            }
            let profile_name = worker
                .metadata()
                .labels
                .get("profile")
                .cloned()
                .unwrap_or_else(|| "default".to_string());

            map.entry(profile_name).or_default().push(idx);
        }

        cache.map = map;
        cache.worker_count = workers.len();

        debug!(
            "[RequestProfiling] Refreshed profile cache: {} workers across {} profiles",
            workers.len(),
            cache.map.len()
        );
    }

    /// Select least-loaded worker from a set of candidate indices
    fn select_least_loaded(workers: &[Arc<dyn Worker>], candidates: &[usize]) -> Option<usize> {
        candidates
            .iter()
            .filter(|&&idx| workers[idx].is_healthy() && workers[idx].circuit_breaker().can_execute())
            .min_by_key(|&&idx| workers[idx].load())
            .copied()
    }
}

impl Default for RequestProfilingPolicy {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LoadBalancingPolicy for RequestProfilingPolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);
        if healthy_indices.is_empty() {
            return None;
        }

        // Refresh profile cache if needed
        self.refresh_profile_cache(workers);

        // Classify the request
        let req_profile = self.classify_request(info);

        // Match to best profile
        let target_profile = self.match_profile(&req_profile);

        debug!(
            "[RequestProfiling] Request classified: input={}, output={}, stream={} -> profile={}",
            req_profile.input_category, req_profile.output_category, req_profile.is_stream, target_profile
        );

        // Try to select from the matched profile
        let cache = self.profile_cache.read();
        if let Some(profile_workers) = cache.get_profile(target_profile) {
            if !profile_workers.is_empty() {
                if let Some(idx) = Self::select_least_loaded(workers, profile_workers) {
                    return Some(idx);
                }
            }
        }

        // Fallback: try "default" profile
        if target_profile != "default" {
            if let Some(default_workers) = cache.get_profile("default") {
                if !default_workers.is_empty() {
                    if let Some(idx) = Self::select_least_loaded(workers, default_workers) {
                        debug!(
                            "[RequestProfiling] Falling back to default profile for request"
                        );
                        return Some(idx);
                    }
                }
            }
        }

        // Final fallback: any healthy worker (least loaded)
        debug!("[RequestProfiling] No profile match, using least-loaded from all healthy workers");
        Self::select_least_loaded(workers, &healthy_indices)
    }

    fn on_request_complete(&self, _worker_url: &str, _success: bool) {
        // Stateless for now; load is tracked via Worker::load()
    }

    fn name(&self) -> &'static str {
        "request_profiling"
    }

    fn needs_request_text(&self) -> bool {
        true // Needs request text for classification
    }

    fn update_loads(&self, _loads: &HashMap<String, isize>) {
        // Invalidate profile cache on load updates (workers may have changed health)
        let mut cache = self.profile_cache.write();
        cache.worker_count = 0; // Force refresh on next select_worker
    }

    fn reset(&self) {
        let mut cache = self.profile_cache.write();
        *cache = ProfileWorkerCache::default();
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl ProfileWorkerCache {
    fn get_profile(&self, name: &str) -> Option<&Vec<usize>> {
        self.map.get(name)
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    fn make_worker(url: &str, profile: &str) -> Arc<dyn Worker> {
        Arc::new(
            BasicWorkerBuilder::new(url)
                .worker_type(WorkerType::Regular)
                .label("profile", profile)
                .build(),
        )
    }

    fn make_worker_no_profile(url: &str) -> Arc<dyn Worker> {
        Arc::new(
            BasicWorkerBuilder::new(url)
                .worker_type(WorkerType::Regular)
                .build(),
        )
    }

    #[test]
    fn test_input_classification() {
        let policy = RequestProfilingPolicy::new();

        // Short input (< 500 chars)
        let info = SelectWorkerInfo {
            request_text: Some("hello"),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Short);

        // Medium input (500..4000 chars)
        let medium_text = "a".repeat(1000);
        let info = SelectWorkerInfo {
            request_text: Some(&medium_text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Medium);

        // Long input (>= 4000 chars)
        let long_text = "b".repeat(5000);
        let info = SelectWorkerInfo {
            request_text: Some(&long_text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Long);
    }

    #[test]
    fn test_max_tokens_extraction() {
        // Standard max_tokens
        let text = r#"{"model":"test","messages":[],"max_tokens":2048}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 2048);

        // max_completion_tokens (OpenAI newer API)
        let text = r#"{"model":"test","max_completion_tokens":4096}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 4096);

        // No max_tokens → default 512
        let text = r#"{"model":"test","messages":[]}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 512);

        // max_tokens with spaces
        let text = r#"{"max_tokens" : 100}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 100);
    }

    #[test]
    fn test_stream_extraction() {
        let text = r#"{"stream":true,"model":"test"}"#;
        assert!(RequestProfilingPolicy::extract_stream(text));

        let text = r#"{"stream":false,"model":"test"}"#;
        assert!(!RequestProfilingPolicy::extract_stream(text));

        let text = r#"{"stream" : true}"#;
        assert!(RequestProfilingPolicy::extract_stream(text));

        let text = r#"{"model":"test"}"#;
        assert!(!RequestProfilingPolicy::extract_stream(text));
    }

    #[test]
    fn test_profile_matching() {
        let policy = RequestProfilingPolicy::new();

        // Short input → "short" profile
        let profile = RequestProfile {
            input_category: InputCategory::Short,
            output_category: OutputCategory::Small,
            is_stream: false,
        };
        assert_eq!(policy.match_profile(&profile), "short");

        // Long input → "long" profile
        let profile = RequestProfile {
            input_category: InputCategory::Long,
            output_category: OutputCategory::Medium,
            is_stream: true,
        };
        assert_eq!(policy.match_profile(&profile), "long");

        // Medium input + large output → "large_output" profile
        let profile = RequestProfile {
            input_category: InputCategory::Medium,
            output_category: OutputCategory::Large,
            is_stream: false,
        };
        assert_eq!(policy.match_profile(&profile), "large_output");

        // Medium input + small output → "default" profile (catch-all)
        let profile = RequestProfile {
            input_category: InputCategory::Medium,
            output_category: OutputCategory::Small,
            is_stream: false,
        };
        assert_eq!(policy.match_profile(&profile), "default");
    }

    #[tokio::test]
    async fn test_worker_profile_binding() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "long"),
            make_worker("http://w3:8000", "default"),
        ];

        // Short request should go to w1 (profile=short)
        let info = SelectWorkerInfo {
            request_text: Some("short request"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0));

        // Long request should go to w2 (profile=long)
        let long_text = "x".repeat(5000);
        let info = SelectWorkerInfo {
            request_text: Some(&long_text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(1));
    }

    #[tokio::test]
    async fn test_fallback_to_default() {
        let policy = RequestProfilingPolicy::new();

        // Only "default" workers, no "short" or "long"
        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "default"),
            make_worker("http://w2:8000", "default"),
        ];

        // Short request has no "short" profile workers → falls back to "default"
        let info = SelectWorkerInfo {
            request_text: Some("short"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert!(idx.is_some());
        assert!(idx.unwrap() <= 1);
    }

    #[tokio::test]
    async fn test_fallback_to_any_healthy() {
        let config = RequestProfilingConfig {
            profiles: vec![
                ProfileRule {
                    name: "special".to_string(),
                    match_input: Some(InputCategory::Short),
                    match_output: None,
                    match_stream: None,
                    priority: 10,
                },
            ],
            ..Default::default()
        };
        let policy = RequestProfilingPolicy::with_config(config);

        // Workers have no matching profiles at all
        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker_no_profile("http://w1:8000"),
            make_worker_no_profile("http://w2:8000"),
        ];

        let info = SelectWorkerInfo {
            request_text: Some("short"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        // Should still select a worker (fallback to any healthy)
        assert!(idx.is_some());
    }

    #[tokio::test]
    async fn test_least_loaded_within_profile() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "short"),
            make_worker("http://w3:8000", "short"),
        ];

        // Simulate load on w1 and w2
        workers[0].increment_load();
        workers[0].increment_load();
        workers[1].increment_load();
        // w3 has 0 load

        let info = SelectWorkerInfo {
            request_text: Some("hi"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        // Should pick w3 (least loaded)
        assert_eq!(idx, Some(2));
    }

    #[tokio::test]
    async fn test_unhealthy_worker_skipped() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "short"),
        ];

        // Mark w1 as unhealthy
        workers[0].set_healthy(false);

        let info = SelectWorkerInfo {
            request_text: Some("short"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        // Should skip w1, pick w2
        assert_eq!(idx, Some(1));
    }

    #[tokio::test]
    async fn test_no_healthy_workers() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "long"),
        ];

        workers[0].set_healthy(false);
        workers[1].set_healthy(false);

        let info = SelectWorkerInfo {
            request_text: Some("hello"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, None);
    }

    #[tokio::test]
    async fn test_output_based_routing() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "large_output"),
            make_worker("http://w3:8000", "default"),
        ];

        // Medium input + large output → should route to large_output profile
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":2048}}"#,
            "a".repeat(1000)
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(1)); // w2 has profile=large_output
    }

    #[tokio::test]
    async fn test_custom_config() {
        let config = RequestProfilingConfig {
            short_input_threshold: 100,
            long_input_threshold: 1000,
            large_output_threshold: 512,
            profiles: vec![
                ProfileRule {
                    name: "gpu_a".to_string(),
                    match_input: Some(InputCategory::Short),
                    match_output: None,
                    match_stream: Some(true),
                    priority: 20,
                },
                ProfileRule {
                    name: "gpu_b".to_string(),
                    match_input: Some(InputCategory::Long),
                    match_output: None,
                    match_stream: None,
                    priority: 10,
                },
                ProfileRule {
                    name: "default".to_string(),
                    match_input: None,
                    match_output: None,
                    match_stream: None,
                    priority: 0,
                },
            ],
        };
        let policy = RequestProfilingPolicy::with_config(config);

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "gpu_a"),
            make_worker("http://w2:8000", "gpu_b"),
            make_worker("http://w3:8000", "default"),
        ];

        // Short + stream=true → gpu_a
        let text = r#"{"stream":true,"messages":[{"content":"hi"}]}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0));

        // Long input → gpu_b
        let long_text = format!(r#"{{"messages":[{{"content":"{}"}}]}}"#, "x".repeat(2000));
        let info = SelectWorkerInfo {
            request_text: Some(&long_text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(1));
    }

    // ─── Additional comprehensive tests ─────────────────────────────────────

    #[test]
    fn test_output_classification() {
        let policy = RequestProfilingPolicy::new();

        // Large output (>= 1024 max_tokens)
        let text = r#"{"max_tokens":2048}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.output_category, OutputCategory::Large);

        // Medium output (>= 256 and < 1024)
        let text = r#"{"max_tokens":512}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.output_category, OutputCategory::Medium);

        // Small output (< 256)
        let text = r#"{"max_tokens":100}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.output_category, OutputCategory::Small);

        // Default (no max_tokens) -> 512 -> Medium
        let text = r#"{"model":"test"}"#;
        let info = SelectWorkerInfo {
            request_text: Some(text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.output_category, OutputCategory::Medium);
    }

    #[test]
    fn test_input_boundaries() {
        let policy = RequestProfilingPolicy::new();

        // Exactly at short threshold boundary (500): < 500 is short, so 500 is Medium
        let text = "a".repeat(500);
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Medium);

        // 499 chars → Short
        let text = "a".repeat(499);
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Short);

        // Exactly at long threshold (4000) → Long
        let text = "b".repeat(4000);
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        assert_eq!(profile.input_category, InputCategory::Long);
    }

    #[test]
    fn test_empty_request_text() {
        let policy = RequestProfilingPolicy::new();
        let info = SelectWorkerInfo {
            request_text: Some(""),
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        // Empty text: 0 chars → short, no max_tokens → 512 → medium output
        assert_eq!(profile.input_category, InputCategory::Short);
        assert_eq!(profile.output_category, OutputCategory::Medium);
    }

    #[test]
    fn test_none_request_text() {
        let policy = RequestProfilingPolicy::new();
        let info = SelectWorkerInfo {
            request_text: None,
            ..Default::default()
        };
        let profile = policy.classify_request(&info);
        // None treated as empty: 0 chars → short
        assert_eq!(profile.input_category, InputCategory::Short);
        assert_eq!(profile.output_category, OutputCategory::Medium);
    }

    #[tokio::test]
    async fn test_worker_no_profile_label_gets_default() {
        let policy = RequestProfilingPolicy::new();

        // Worker without any label should be treated as "default"
        let workers: Vec<Arc<dyn Worker>> = vec![make_worker_no_profile("http://w1:8000")];

        // Medium input + small output → "default" profile
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":100}}"#,
            "a".repeat(1000)
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0));
    }

    #[tokio::test]
    async fn test_medium_input_routes_to_default() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "long"),
            make_worker("http://w3:8000", "default"),
        ];

        // Medium input + small output → should match "default" (no other rule matches)
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":100}}"#,
            "a".repeat(1000)
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(2)); // w3 is default
    }

    #[tokio::test]
    async fn test_fallback_when_matched_profile_all_unhealthy() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "short"),
            make_worker("http://w3:8000", "default"),
        ];

        // Both "short" workers unhealthy → should fallback to "default"
        workers[0].set_healthy(false);
        workers[1].set_healthy(false);

        let info = SelectWorkerInfo {
            request_text: Some("hello"),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(2)); // w3 is default
    }

    #[tokio::test]
    async fn test_fallback_when_default_also_unhealthy() {
        let policy = RequestProfilingPolicy::new();

        // Only "special" profile workers, no "default" label workers
        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "special"),
            make_worker("http://w2:8000", "gpu_b"),
        ];

        // Medium input → no matching profile → tries "default" → no default workers
        // → final fallback to any healthy worker
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":100}}"#,
            "a".repeat(1000)
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert!(idx.is_some());
    }

    #[test]
    fn test_reset_clears_cache() {
        let policy = RequestProfilingPolicy::new();

        // Build cache by accessing it via profile_cache write
        {
            let mut cache = policy.profile_cache.write();
            cache.map.insert("test".to_string(), vec![0]);
            cache.worker_count = 3;
        }

        policy.reset();

        let cache = policy.profile_cache.read();
        assert!(cache.map.is_empty());
        assert_eq!(cache.worker_count, 0);
    }

    #[test]
    fn test_name_and_needs_request_text() {
        let policy = RequestProfilingPolicy::new();
        assert_eq!(policy.name(), "request_profiling");
        assert!(policy.needs_request_text());
    }

    #[test]
    fn test_profile_priority_ordering() {
        // Two rules could match: "stream_short" (priority=20, stream+short) vs
        // "short" (priority=10, short only). Higher priority should win.
        let config = RequestProfilingConfig {
            profiles: vec![
                ProfileRule {
                    name: "short".to_string(),
                    match_input: Some(InputCategory::Short),
                    match_output: None,
                    match_stream: None,
                    priority: 10,
                },
                ProfileRule {
                    name: "stream_short".to_string(),
                    match_input: Some(InputCategory::Short),
                    match_output: None,
                    match_stream: Some(true),
                    priority: 20,
                },
                ProfileRule {
                    name: "default".to_string(),
                    match_input: None,
                    match_output: None,
                    match_stream: None,
                    priority: 0,
                },
            ],
            ..Default::default()
        };
        let policy = RequestProfilingPolicy::with_config(config);

        // Short + stream → "stream_short" (priority 20 beats priority 10)
        let profile = RequestProfile {
            input_category: InputCategory::Short,
            output_category: OutputCategory::Small,
            is_stream: true,
        };
        assert_eq!(policy.match_profile(&profile), "stream_short");

        // Short + no stream → "short" (stream_short doesn't match)
        let profile = RequestProfile {
            input_category: InputCategory::Short,
            output_category: OutputCategory::Small,
            is_stream: false,
        };
        assert_eq!(policy.match_profile(&profile), "short");
    }

    #[tokio::test]
    async fn test_long_input_matches_before_large_output() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "long"),
            make_worker("http://w2:8000", "large_output"),
        ];

        // Long input + large output: both "long" (priority 10) and "large_output" (priority 5)
        // match. "long" should win due to higher priority.
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":2048}}"#,
            "x".repeat(5000)
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0)); // w1=long wins over w2=large_output
    }

    #[tokio::test]
    async fn test_cache_rebuilt_after_worker_count_change() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "long"),
        ];

        // First call builds cache
        let info = SelectWorkerInfo {
            request_text: Some("hello"),
            ..Default::default()
        };
        let _ = policy.select_worker(&workers, &info).await;

        // Verify cache was built
        {
            let cache = policy.profile_cache.read();
            assert_eq!(cache.worker_count, 2);
            assert!(cache.map.contains_key("short"));
            assert!(cache.map.contains_key("long"));
        }

        // Add a new worker → cache should be rebuilt on next select
        let workers2: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
            make_worker("http://w2:8000", "long"),
            make_worker("http://w3:8000", "default"),
        ];

        let _ = policy.select_worker(&workers2, &info).await;
        {
            let cache = policy.profile_cache.read();
            assert_eq!(cache.worker_count, 3);
            assert!(cache.map.contains_key("default"));
        }
    }

    #[tokio::test]
    async fn test_update_loads_invalidates_cache() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "short"),
        ];

        // Build cache
        let info = SelectWorkerInfo {
            request_text: Some("hello"),
            ..Default::default()
        };
        let _ = policy.select_worker(&workers, &info).await;

        // Cache should be populated
        {
            let cache = policy.profile_cache.read();
            assert_eq!(cache.worker_count, 1);
        }

        // update_loads should invalidate cache
        policy.update_loads(&HashMap::new());
        {
            let cache = policy.profile_cache.read();
            assert_eq!(cache.worker_count, 0);
        }
    }

    #[tokio::test]
    async fn test_large_output_threshold_boundary() {
        let policy = RequestProfilingPolicy::new();

        let workers: Vec<Arc<dyn Worker>> = vec![
            make_worker("http://w1:8000", "large_output"),
            make_worker("http://w2:8000", "default"),
        ];

        // Exactly at large_output_threshold (1024) → should be "Large"
        let text = format!(
            r#"{{"messages":[{{"content":"{}"}}],"max_tokens":1024}}"#,
            "a".repeat(1000) // medium input
        );
        let info = SelectWorkerInfo {
            request_text: Some(&text),
            ..Default::default()
        };
        let idx = policy.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0)); // w1 is large_output
    }

    #[test]
    fn test_max_completion_tokens_with_spaces() {
        // max_completion_tokens with space before colon
        let text = r#"{"max_completion_tokens" : 2048}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 2048);
    }

    #[test]
    fn test_stream_with_spaces() {
        // stream with space before colon
        let text = r#"{"stream" : true}"#;
        assert!(RequestProfilingPolicy::extract_stream(text));
    }

    #[test]
    fn test_extract_max_tokens_first_value_wins() {
        // max_tokens appears before max_completion_tokens; max_tokens should win
        let text = r#"{"max_tokens":256,"max_completion_tokens":4096}"#;
        assert_eq!(RequestProfilingPolicy::extract_max_tokens(text), 256);
    }

    #[tokio::test]
    async fn test_default_policy_name() {
        let policy = RequestProfilingPolicy::default();
        assert_eq!(policy.name(), "request_profiling");
    }
}

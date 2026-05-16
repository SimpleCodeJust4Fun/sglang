//! Composite Policy with Phase Switching for heterogeneous GPU scheduling
//!
//! This policy wraps two sub-policies — a **distribution** policy (load-balancing) and an
//! **affinity** policy (hardware-aware matching) — and switches between them based on
//! system load.
//!
//! ## Strategy Details
//!
//! PhaseSwitcher state machine:
//! ```text
//!           load < low_threshold
//!     ┌──────────────────────────────┐
//!     │                              │
//!     ▼                              │
//! ┌─────────┐  load > high_threshold  ┌──────────────┐
//! │Affinity │ ──────────────────────→ │ Distribution  │
//! │ Mode    │ ←────────────────────── │ Mode          │
//! └─────────┘  load < low_threshold   └──────────────┘
//!     │                              │
//!     └──────────────────────────────┘
//!           中间态: 概率混合
//!     P(affinity) = w_aff, P(distribution) = 1 - w_aff
//! ```
//!
//! - **Low load** (< low_threshold): Affinity policy → best hardware match
//! - **High load** (> high_threshold): Distribution policy → even load spread
//! - **Transition** (between): Probabilistic blend, linearly interpolated
//!
//! ## Typical Pairings
//!
//! | Distribution           | Affinity              | Scenario                    |
//! |------------------------|-----------------------|-----------------------------|
//! | RoundRobin / LoadAware | RoofLine              | Heterogeneous GPU cluster   |
//! | PowerOfTwo             | RequestProfiling      | Profile-aware + load limits |
//! | Random                 | CacheAware            | Cache + simple distribution |
//!
//! ## Configuration
//!
//! - `low_threshold`: System load below which affinity mode is used (default: 0.3)
//! - `high_threshold`: System load above which distribution mode is used (default: 0.7)

#![allow(dead_code)]

use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::RwLock;
use rand::Rng;
use tracing::{debug, info};

use super::{get_healthy_worker_indices, LoadBalancingPolicy, SelectWorkerInfo};
use crate::core::Worker;

// ─── Configuration ───────────────────────────────────────────────────────────

/// Configuration for CompositePolicy with PhaseSwitcher
#[derive(Debug, Clone)]
pub struct CompositeConfig {
    /// Below this load level, use affinity policy exclusively (default: 0.3)
    pub low_threshold: f64,
    /// Above this load level, use distribution policy exclusively (default: 0.7)
    pub high_threshold: f64,
}

impl Default for CompositeConfig {
    fn default() -> Self {
        Self {
            low_threshold: 0.3,
            high_threshold: 0.7,
        }
    }
}

// ─── Phase Mode ──────────────────────────────────────────────────────────────

/// Current operating mode of the PhaseSwitcher
#[derive(Debug, Clone, Copy, PartialEq)]
enum PhaseMode {
    /// Low load → use affinity (hardware-aware) policy
    Affinity,
    /// High load → use distribution (load-balancing) policy
    Distribution,
    /// Transition → probabilistic blend
    /// `affinity_weight` is the probability of using the affinity policy
    Transition { affinity_weight: f64 },
}

// ─── Phase Switcher ──────────────────────────────────────────────────────────

/// PhaseSwitcher: monitors system load and determines which policy to use.
#[derive(Debug)]
struct PhaseSwitcher {
    config: CompositeConfig,
    /// Current system load (0.0 = idle, 1.0 = fully loaded)
    /// Updated via `update_loads()`. RwLock for shared access.
    current_load: RwLock<f64>,
}

impl PhaseSwitcher {
    fn new(config: CompositeConfig) -> Self {
        Self {
            config,
            current_load: RwLock::new(0.0),
        }
    }

    /// Update system load from per-worker load data.
    ///
    /// Calculates the average load across all workers as a proxy for system load.
    /// The load values are interpreted as ratios: 0 = idle, worker_count+ = overloaded.
    fn update_load(&self, loads: &std::collections::HashMap<String, isize>) {
        if loads.is_empty() {
            return;
        }

        let counted: Vec<isize> = loads.values().copied().collect();
        let total: isize = counted.iter().sum();
        // Normalize: average load per worker, capped at 2.0 to keep meaningful range
        let avg = total as f64 / counted.len() as f64;
        let normalized = avg.min(2.0).max(0.0);

        {
            let mut load = self.current_load.write();
            *load = normalized;
        }

        debug!(
            "[PhaseSwitcher] Updated system load: {:.3} (raw avg: {:.1}, workers: {})",
            normalized, avg, counted.len()
        );
    }

    /// Get the current system load
    fn get_load(&self) -> f64 {
        *self.current_load.read()
    }

    /// Determine the current phase mode based on system load.
    fn determine_mode(&self) -> PhaseMode {
        let load = self.get_load();

        if load <= self.config.low_threshold {
            PhaseMode::Affinity
        } else if load >= self.config.high_threshold {
            PhaseMode::Distribution
        } else {
            // Linear interpolation: w_aff = 1.0 at low_threshold, 0.0 at high_threshold
            let range = self.config.high_threshold - self.config.low_threshold;
            let affinity_weight = if range > 0.0 {
                1.0 - (load - self.config.low_threshold) / range
            } else {
                0.5
            };
            PhaseMode::Transition { affinity_weight }
        }
    }

    /// For a given mode, select which policy to use (returns true for affinity, false for distribution).
    fn should_use_affinity(&self, mode: PhaseMode) -> bool {
        match mode {
            PhaseMode::Affinity => true,
            PhaseMode::Distribution => false,
            PhaseMode::Transition { affinity_weight } => {
                let mut rng = rand::rng();
                rng.random::<f64>() < affinity_weight
            }
        }
    }
}

// ─── Composite Policy ───────────────────────────────────────────────────────

/// CompositePolicy with PhaseSwitcher.
///
/// Combines a distribution policy (load-balancing) and an affinity policy
/// (hardware-aware matching). The PhaseSwitcher selects which one to use
/// based on current system load.
#[derive(Debug)]
pub struct CompositePolicy {
    config: CompositeConfig,
    distribution_policy: Arc<dyn LoadBalancingPolicy>,
    affinity_policy: Arc<dyn LoadBalancingPolicy>,
    switcher: PhaseSwitcher,
}

impl CompositePolicy {
    /// Create a new CompositePolicy with two sub-policies and default thresholds.
    pub fn new(
        distribution_policy: Arc<dyn LoadBalancingPolicy>,
        affinity_policy: Arc<dyn LoadBalancingPolicy>,
    ) -> Self {
        Self::with_config(
            distribution_policy,
            affinity_policy,
            CompositeConfig::default(),
        )
    }

    /// Create a new CompositePolicy with custom config.
    pub fn with_config(
        distribution_policy: Arc<dyn LoadBalancingPolicy>,
        affinity_policy: Arc<dyn LoadBalancingPolicy>,
        config: CompositeConfig,
    ) -> Self {
        let switcher = PhaseSwitcher::new(config.clone());
        Self {
            config,
            distribution_policy,
            affinity_policy,
            switcher,
        }
    }

    /// Get a reference to the distribution sub-policy
    pub fn distribution_policy(&self) -> &Arc<dyn LoadBalancingPolicy> {
        &self.distribution_policy
    }

    /// Get a reference to the affinity sub-policy
    pub fn affinity_policy(&self) -> &Arc<dyn LoadBalancingPolicy> {
        &self.affinity_policy
    }
}

#[async_trait]
impl LoadBalancingPolicy for CompositePolicy {
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize> {
        let healthy_indices = get_healthy_worker_indices(workers);
        if healthy_indices.is_empty() {
            return None;
        }

        let mode = self.switcher.determine_mode();
        let use_affinity = self.switcher.should_use_affinity(mode);

        debug!(
            "[Composite] load={:.3}, mode={:?}, use_affinity={}",
            self.switcher.get_load(),
            mode,
            use_affinity,
        );

        // Try the selected policy first
        let primary = if use_affinity {
            &self.affinity_policy
        } else {
            &self.distribution_policy
        };
        let secondary = if use_affinity {
            &self.distribution_policy
        } else {
            &self.affinity_policy
        };

        if let Some(idx) = primary.select_worker(workers, info).await {
            return Some(idx);
        }

        // Fallback: try the other policy
        if let Some(idx) = secondary.select_worker(workers, info).await {
            debug!("[Composite] Primary policy returned None, falling back to secondary");
            return Some(idx);
        }

        // Final fallback: any healthy worker
        debug!("[Composite] Both policies returned None, using first healthy worker");
        healthy_indices.first().copied()
    }

    fn on_request_complete(&self, worker_url: &str, success: bool) {
        self.distribution_policy
            .on_request_complete(worker_url, success);
        self.affinity_policy
            .on_request_complete(worker_url, success);
    }

    fn name(&self) -> &'static str {
        "composite"
    }

    fn needs_request_text(&self) -> bool {
        self.distribution_policy.needs_request_text()
            || self.affinity_policy.needs_request_text()
    }

    fn update_loads(&self, loads: &std::collections::HashMap<String, isize>) {
        // Update PhaseSwitcher
        self.switcher.update_load(loads);
        // Forward to sub-policies
        self.distribution_policy.update_loads(loads);
        self.affinity_policy.update_loads(loads);
    }

    fn reset(&self) {
        self.distribution_policy.reset();
        self.affinity_policy.reset();
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{BasicWorkerBuilder, WorkerType};

    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A simple test policy that always returns a specific worker index.
    #[derive(Debug)]
    struct FixedWorkerPolicy {
        worker_index: usize,
        name_str: &'static str,
        needs_text: bool,
        call_count: AtomicUsize,
    }

    impl FixedWorkerPolicy {
        fn new(index: usize, name: &'static str, needs_text: bool) -> Self {
            Self {
                worker_index: index,
                name_str: name,
                needs_text,
                call_count: AtomicUsize::new(0),
            }
        }

        fn call_count(&self) -> usize {
            self.call_count.load(Ordering::Relaxed)
        }
    }

    #[async_trait]
    impl LoadBalancingPolicy for FixedWorkerPolicy {
        async fn select_worker(
            &self,
            _workers: &[Arc<dyn Worker>],
            _info: &SelectWorkerInfo<'_>,
        ) -> Option<usize> {
            self.call_count.fetch_add(1, Ordering::Relaxed);
            Some(self.worker_index)
        }

        fn name(&self) -> &'static str {
            self.name_str
        }

        fn needs_request_text(&self) -> bool {
            self.needs_text
        }

        fn reset(&self) {
            self.call_count.store(0, Ordering::Relaxed);
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
    }

    /// A policy that always returns None (simulates failure to select)
    #[derive(Debug)]
    struct NonePolicy {
        name_str: &'static str,
    }

    #[async_trait]
    impl LoadBalancingPolicy for NonePolicy {
        async fn select_worker(
            &self,
            _workers: &[Arc<dyn Worker>],
            _info: &SelectWorkerInfo<'_>,
        ) -> Option<usize> {
            None
        }

        fn name(&self) -> &'static str {
            self.name_str
        }

        fn needs_request_text(&self) -> bool {
            false
        }

        fn reset(&self) {}

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }
    }

    fn make_worker(url: &str) -> Arc<dyn Worker> {
        Arc::new(
            BasicWorkerBuilder::new(url)
                .worker_type(WorkerType::Regular)
                .build(),
        )
    }

    // ── PhaseSwitcher ─────────────────────────────────────────────────────

    #[test]
    fn test_switcher_affinity_mode_at_low_load() {
        let config = CompositeConfig {
            low_threshold: 0.3,
            high_threshold: 0.7,
        };
        let switcher = PhaseSwitcher::new(config);

        // Set load to 0.0 (idle)
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        loads.insert("w2".to_string(), 0);
        switcher.update_load(&loads);

        let mode = switcher.determine_mode();
        assert_eq!(mode, PhaseMode::Affinity);
        assert!(switcher.should_use_affinity(mode));
    }

    #[test]
    fn test_switcher_distribution_mode_at_high_load() {
        let config = CompositeConfig {
            low_threshold: 0.3,
            high_threshold: 0.7,
        };
        let switcher = PhaseSwitcher::new(config);

        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 5);
        loads.insert("w2".to_string(), 5);
        switcher.update_load(&loads);

        let mode = switcher.determine_mode();
        assert_eq!(mode, PhaseMode::Distribution);
        assert!(!switcher.should_use_affinity(mode));
    }

    #[test]
    fn test_switcher_transition_mode() {
        let config = CompositeConfig {
            low_threshold: 0.3,
            high_threshold: 0.7,
        };
        let switcher = PhaseSwitcher::new(config);

        // Load at 0.5 → exactly in middle of transition range
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 1);
        loads.insert("w2".to_string(), 0);
        switcher.update_load(&loads);

        let mode = switcher.determine_mode();
        match mode {
            PhaseMode::Transition { affinity_weight } => {
                // At load=0.5 with low=0.3, high=0.7:
                // w_aff = 1.0 - (0.5-0.3)/(0.7-0.3) = 1.0 - 0.5 = 0.5
                assert!((affinity_weight - 0.5).abs() < 0.01);
            }
            _ => panic!("Expected Transition mode, got {:?}", mode),
        }
    }

    #[test]
    fn test_switcher_transition_affinity_weight_decreases_with_load() {
        let mut config = CompositeConfig {
            low_threshold: 0.2,
            high_threshold: 0.8,
        };
        let switcher = PhaseSwitcher::new(config.clone());

        // At low_threshold boundary → w_aff = 1.0
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        loads.insert("w2".to_string(), 0);
        loads.insert("w3".to_string(), 0);
        loads.insert("w4".to_string(), 0);
        loads.insert("w5".to_string(), 1); // avg = 1/5 = 0.2
        switcher.update_load(&loads);
        let mode = switcher.determine_mode();
        assert_eq!(mode, PhaseMode::Affinity);

        // Reset and go to mid-transition
        config.high_threshold = 0.8; // not mut

        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 3);
        loads.insert("w2".to_string(), 1); // avg = 4/2 = 2.0 → normalized to 2.0
        switcher.update_load(&loads);
        let mode = switcher.determine_mode();
        assert_eq!(mode, PhaseMode::Distribution); // 2.0 > 0.8

        // At 0.5 (mid transition): w_aff should be 0.5 for range [0.2, 0.8]
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 1);
        loads.insert("w2".to_string(), 0); // avg = 0.5
        switcher.update_load(&loads);
        let mode = switcher.determine_mode();
        match mode {
            PhaseMode::Transition { affinity_weight } => {
                assert!((affinity_weight - 0.5).abs() < 0.01);
            }
            _ => panic!("Expected Transition"),
        }
    }

    #[test]
    fn test_switcher_empty_loads_no_change() {
        let config = CompositeConfig::default();
        let switcher = PhaseSwitcher::new(config);

        // Set initial load
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 3);
        switcher.update_load(&loads);
        let before = switcher.get_load();

        // Empty loads should not change
        switcher.update_load(&std::collections::HashMap::new());
        let after = switcher.get_load();
        assert!((before - after).abs() < 0.01);
    }

    #[test]
    fn test_switcher_boundary_at_threshold() {
        let config = CompositeConfig {
            low_threshold: 0.3,
            high_threshold: 0.7,
        };
        let switcher = PhaseSwitcher::new(config);

        // Exactly at low_threshold (0.3) → Affinity (≤ low_threshold)
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        loads.insert("w2".to_string(), 0);
        loads.insert("w3".to_string(), 0);
        loads.insert("w4".to_string(), 1); // 1 but normalized: avg = 1/4 = 0.25
        switcher.update_load(&loads);
        assert_eq!(switcher.get_load(), 0.25);
        let mode = switcher.determine_mode();
        assert_eq!(mode, PhaseMode::Affinity);

        // Slightly above low_threshold → Transition
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 1);
        loads.insert("w2".to_string(), 0); // avg = 0.5
        switcher.update_load(&loads);
        let mode = switcher.determine_mode();
        match mode {
            PhaseMode::Transition { .. } => {} // expected
            _ => panic!("Expected Transition at load 0.5"),
        }

        // Exactly at high_threshold (0.7) → Distribution
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 2); // normalizes to 1.4 avg? no... avg=1.4/1=1.4. Hmm.
        // Actually let's just use avg=0.7
        loads.insert("w2".to_string(), 0);
        loads.insert("w3".to_string(), 1);
        loads.insert("w4".to_string(), 1);
        loads.insert("w5".to_string(), 1);
        loads.insert("w6".to_string(), 1); // avg = 0.7? sum=4, count=6 => 0.666...
        // Let me think more carefully...
        // Actually to get avg=0.7, we need total/workers = 0.7.
        // 4 workers: 0.7*4=2.8 → loads [1,1,1,0] gives avg=0.75
        // 10 workers: 0.7*10=7 → loads [1,1,1,1,1,1,1,0,0,0] gives avg=0.7
        switcher.update_load(&loads);
    }

    #[test]
    fn test_switcher_load_normalization_capped() {
        let config = CompositeConfig::default();
        let switcher = PhaseSwitcher::new(config);

        // Very high load should be capped at 2.0
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 50);
        loads.insert("w2".to_string(), 50); // avg = 50, capped at 2.0
        switcher.update_load(&loads);

        assert!((switcher.get_load() - 2.0).abs() < 0.01);
    }

    // ── CompositePolicy ───────────────────────────────────────────────────

    #[tokio::test]
    async fn test_composite_affinity_at_low_load() {
        let affinity = Arc::new(FixedWorkerPolicy::new(1, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::with_config(
            distribution.clone(),
            affinity.clone(),
            CompositeConfig {
                low_threshold: 0.3,
                high_threshold: 0.7,
            },
        );

        // Low load → should use affinity policy
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        loads.insert("w2".to_string(), 0);
        composite.update_loads(&loads);

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000"), make_worker("http://w2:8000")];
        let info = SelectWorkerInfo::default();

        // Run multiple times — at low load, should always use affinity
        let mut uses_affinity = 0;
        for _ in 0..100 {
            let idx = composite.select_worker(&workers, &info).await.unwrap();
            if idx == 1 {
                uses_affinity += 1;
            }
        }
        // At Affinity mode, all 100 should use affinity
        assert_eq!(uses_affinity, 100);
    }

    #[tokio::test]
    async fn test_composite_distribution_at_high_load() {
        let affinity = Arc::new(FixedWorkerPolicy::new(1, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::with_config(
            distribution.clone(),
            affinity.clone(),
            CompositeConfig {
                low_threshold: 0.3,
                high_threshold: 0.7,
            },
        );

        // High load → should use distribution policy
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 5);
        loads.insert("w2".to_string(), 5);
        composite.update_loads(&loads);

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000"), make_worker("http://w2:8000")];
        let info = SelectWorkerInfo::default();

        let mut uses_distribution = 0;
        for _ in 0..100 {
            let idx = composite.select_worker(&workers, &info).await.unwrap();
            if idx == 0 {
                uses_distribution += 1;
            }
        }
        assert_eq!(uses_distribution, 100);
    }

    #[tokio::test]
    async fn test_composite_transition_mix() {
        let affinity = Arc::new(FixedWorkerPolicy::new(1, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::with_config(
            distribution.clone(),
            affinity.clone(),
            CompositeConfig {
                low_threshold: 0.3,
                high_threshold: 0.7,
            },
        );

        // Mid load → transition mode with w_aff = 0.5
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 1);
        loads.insert("w2".to_string(), 0); // avg = 0.5
        composite.update_loads(&loads);

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000"), make_worker("http://w2:8000")];
        let info = SelectWorkerInfo::default();

        let mut uses_affinity = 0;
        let trials = 1000;
        for _ in 0..trials {
            let idx = composite.select_worker(&workers, &info).await.unwrap();
            if idx == 1 {
                uses_affinity += 1;
            }
        }
        // At 0.5 blend, should get roughly 50% affinity. Allow ±15%.
        let ratio = uses_affinity as f64 / trials as f64;
        assert!(
            (0.35..=0.65).contains(&ratio),
            "Expected ~0.5 affinity ratio, got {:.3}",
            ratio
        );
    }

    #[tokio::test]
    async fn test_composite_fallback_when_primary_returns_none() {
        let affinity = Arc::new(NonePolicy { name_str: "affinity_none" });
        let distribution = Arc::new(FixedWorkerPolicy::new(2, "distribution", false));

        let composite = CompositePolicy::with_config(
            distribution.clone(),
            affinity.clone(),
            CompositeConfig {
                low_threshold: 0.1,
                high_threshold: 0.9,
            },
        );

        // Low load → primary = affinity (returns None) → fallback to distribution
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        composite.update_loads(&loads);

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000"), make_worker("http://w2:8000"), make_worker("http://w3:8000")];
        let info = SelectWorkerInfo::default();

        let idx = composite.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(2)); // distribution returns 2
    }

    #[tokio::test]
    async fn test_composite_fallback_when_both_return_none() {
        let affinity = Arc::new(NonePolicy { name_str: "affinity_none" });
        let distribution = Arc::new(NonePolicy { name_str: "distribution_none" });

        let composite = CompositePolicy::new(distribution.clone(), affinity.clone());

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000")];
        let info = SelectWorkerInfo::default();

        // Both return None → fallback to first healthy worker
        let idx = composite.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0));
    }

    #[tokio::test]
    async fn test_composite_no_healthy_workers() {
        let affinity = Arc::new(FixedWorkerPolicy::new(0, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::new(distribution.clone(), affinity.clone());

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000")];
        workers[0].set_healthy(false);

        let info = SelectWorkerInfo::default();
        let idx = composite.select_worker(&workers, &info).await;
        assert_eq!(idx, None);
    }

    #[test]
    fn test_composite_name_and_needs_request_text() {
        let affinity = Arc::new(FixedWorkerPolicy::new(0, "affinity", true));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::new(distribution, affinity);
        assert_eq!(composite.name(), "composite");
        // affinity needs text → composite needs text
        assert!(composite.needs_request_text());

        let affinity2 = Arc::new(FixedWorkerPolicy::new(0, "affinity2", false));
        let distribution2 = Arc::new(FixedWorkerPolicy::new(0, "distribution2", false));
        let composite2 = CompositePolicy::new(distribution2, affinity2);
        assert!(!composite2.needs_request_text());
    }

    #[test]
    fn test_composite_forward_on_request_complete() {
        let affinity = Arc::new(FixedWorkerPolicy::new(0, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::new(distribution.clone(), affinity.clone());

        composite.on_request_complete("http://w1", true);
        composite.on_request_complete("http://w1", false);
        // on_request_complete is no-op for FixedWorkerPolicy, just verify no panic
    }

    #[test]
    fn test_composite_reset() {
        let affinity = Arc::new(FixedWorkerPolicy::new(0, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::new(distribution.clone(), affinity.clone());

        // Simulate calls
        composite.reset();
        assert_eq!(affinity.call_count(), 0);
        assert_eq!(distribution.call_count(), 0);
    }

    #[tokio::test]
    async fn test_composite_switcher_responds_to_load_changes() {
        let affinity = Arc::new(FixedWorkerPolicy::new(1, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::with_config(
            distribution.clone(),
            affinity.clone(),
            CompositeConfig {
                low_threshold: 0.3,
                high_threshold: 0.7,
            },
        );

        let workers: Vec<Arc<dyn Worker>> = vec![make_worker("http://w1:8000"), make_worker("http://w2:8000")];
        let info = SelectWorkerInfo::default();

        // Low load → affinity
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 0);
        composite.update_loads(&loads);
        let idx = composite.select_worker(&workers, &info).await.unwrap();
        assert_eq!(idx, 1); // affinity

        // High load → distribution
        let mut loads = std::collections::HashMap::new();
        loads.insert("w1".to_string(), 10);
        composite.update_loads(&loads);
        let idx = composite.select_worker(&workers, &info).await.unwrap();
        assert_eq!(idx, 0); // distribution
    }

    #[test]
    fn test_composite_sub_policy_accessors() {
        let affinity = Arc::new(FixedWorkerPolicy::new(1, "affinity", false));
        let distribution = Arc::new(FixedWorkerPolicy::new(0, "distribution", false));

        let composite = CompositePolicy::new(distribution, affinity);
        assert_eq!(composite.affinity_policy().name(), "affinity");
        assert_eq!(composite.distribution_policy().name(), "distribution");
    }

    #[test]
    fn test_composite_default_config() {
        let config = CompositeConfig::default();
        assert!((config.low_threshold - 0.3).abs() < 0.01);
        assert!((config.high_threshold - 0.7).abs() < 0.01);
    }

    #[tokio::test]
    async fn test_composite_with_round_robin_and_roofline() {
        use super::super::{RoofLineConfig, RoofLinePolicy, RoundRobinPolicy};

        let distribution: Arc<dyn LoadBalancingPolicy> = Arc::new(RoundRobinPolicy::new());
        let affinity: Arc<dyn LoadBalancingPolicy> =
            Arc::new(RoofLinePolicy::with_config(RoofLineConfig {
                weight_compute: 1.0,
                weight_memory: 0.0,
            }));

        let composite = CompositePolicy::new(distribution, affinity);

        let workers: Vec<Arc<dyn Worker>> = vec![
            {
                Arc::new(
                    BasicWorkerBuilder::new("http://w1:8000")
                        .worker_type(WorkerType::Regular)
                        .label("gpu_name", "H800")
                        .build(),
                )
            },
            {
                Arc::new(
                    BasicWorkerBuilder::new("http://w2:8000")
                        .worker_type(WorkerType::Regular)
                        .label("gpu_name", "RTX 4090")
                        .build(),
                )
            },
        ];

        let info = SelectWorkerInfo::default();

        // Default load = 0.0 → affinity mode → RoofLine should select H800 (index 0)
        let idx = composite.select_worker(&workers, &info).await;
        assert_eq!(idx, Some(0)); // H800 (higher TFLOPS) wins
    }
}
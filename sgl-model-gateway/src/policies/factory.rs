//! Factory for creating load balancing policies

use std::sync::Arc;

use super::{
    BucketConfig, BucketPolicy, CacheAwareConfig, CacheAwarePolicy, CompositeConfig, CompositePolicy,
    ConsistentHashingPolicy, LoadBalancingPolicy, ManualConfig, ManualPolicy, PerformanceAwareConfig,
    PerformanceAwarePolicy, PowerOfTwoPolicy, PrefixHashConfig, PrefixHashPolicy, RandomPolicy,
    RequestClassificationConfig, RequestClassificationPolicy, RequestProfilingConfig,
    RequestProfilingPolicy, RequestSizeBucketConfig, RequestSizeBucketPolicy, RoofLineConfig,
    RoofLinePolicy, RoundRobinPolicy,
};
use crate::config::PolicyConfig;

/// Factory for creating policy instances
pub struct PolicyFactory;

impl PolicyFactory {
    /// Create a policy from configuration
    pub fn create_from_config(config: &PolicyConfig) -> Arc<dyn LoadBalancingPolicy> {
        match config {
            PolicyConfig::Random => Arc::new(RandomPolicy::new()),
            PolicyConfig::RoundRobin => Arc::new(RoundRobinPolicy::new()),
            PolicyConfig::PowerOfTwo { .. } => Arc::new(PowerOfTwoPolicy::new()),
            PolicyConfig::CacheAware {
                cache_threshold,
                balance_abs_threshold,
                balance_rel_threshold,
                eviction_interval_secs,
                max_tree_size,
            } => {
                let config = CacheAwareConfig {
                    cache_threshold: *cache_threshold,
                    balance_abs_threshold: *balance_abs_threshold,
                    balance_rel_threshold: *balance_rel_threshold,
                    eviction_interval_secs: *eviction_interval_secs,
                    max_tree_size: *max_tree_size,
                };
                Arc::new(CacheAwarePolicy::with_config(config))
            }
            PolicyConfig::Bucket {
                balance_abs_threshold,
                balance_rel_threshold,
                bucket_adjust_interval_secs,
            } => {
                let config = BucketConfig {
                    balance_abs_threshold: *balance_abs_threshold,
                    balance_rel_threshold: *balance_rel_threshold,
                    bucket_adjust_interval_secs: *bucket_adjust_interval_secs,
                };
                Arc::new(BucketPolicy::with_config(config))
            }
            PolicyConfig::Manual {
                eviction_interval_secs,
                max_idle_secs,
                assignment_mode,
            } => {
                let config = ManualConfig {
                    eviction_interval_secs: *eviction_interval_secs,
                    max_idle_secs: *max_idle_secs,
                    assignment_mode: *assignment_mode,
                };
                Arc::new(ManualPolicy::with_config(config))
            }
            PolicyConfig::ConsistentHashing => Arc::new(ConsistentHashingPolicy::new()),
            PolicyConfig::PrefixHash {
                prefix_token_count,
                load_factor,
            } => {
                let config = PrefixHashConfig {
                    prefix_token_count: *prefix_token_count,
                    load_factor: *load_factor,
                };
                Arc::new(PrefixHashPolicy::new(config))
            }
            PolicyConfig::RequestSizeBucket {
                short_threshold,
                medium_threshold,
                track_load_per_bucket,
            } => {
                let config = RequestSizeBucketConfig {
                    short_threshold: *short_threshold,
                    medium_threshold: *medium_threshold,
                    track_load_per_bucket: *track_load_per_bucket,
                };
                Arc::new(RequestSizeBucketPolicy::with_config(config))
            }
            PolicyConfig::PerformanceAware {
                weight_ttft,
                weight_tpot,
                weight_throughput,
                score_refresh_interval_secs,
                consider_load,
            } => {
                let config = PerformanceAwareConfig {
                    weight_ttft: *weight_ttft,
                    weight_tpot: *weight_tpot,
                    weight_throughput: *weight_throughput,
                    score_refresh_interval_secs: *score_refresh_interval_secs,
                    consider_load: *consider_load,
                };
                Arc::new(PerformanceAwarePolicy::with_config(config))
            }
            PolicyConfig::RequestClassification {
                short_input_threshold,
                medium_input_threshold,
                small_output_threshold,
                medium_output_threshold,
                auto_assign_workers,
            } => {
                let config = RequestClassificationConfig {
                    short_input_threshold: *short_input_threshold,
                    medium_input_threshold: *medium_input_threshold,
                    small_output_threshold: *small_output_threshold,
                    medium_output_threshold: *medium_output_threshold,
                    auto_assign_workers: *auto_assign_workers,
                };
                Arc::new(RequestClassificationPolicy::with_config(config))
            }
            PolicyConfig::RequestProfiling {
                short_input_threshold,
                long_input_threshold,
                large_output_threshold,
            } => {
                let config = RequestProfilingConfig {
                    short_input_threshold: *short_input_threshold,
                    long_input_threshold: *long_input_threshold,
                    large_output_threshold: *large_output_threshold,
                    ..Default::default()
                };
                Arc::new(RequestProfilingPolicy::with_config(config))
            }
            PolicyConfig::RoofLine {
                weight_compute,
                weight_memory,
            } => {
                let config = RoofLineConfig {
                    weight_compute: *weight_compute,
                    weight_memory: *weight_memory,
                };
                Arc::new(RoofLinePolicy::with_config(config))
            }
            PolicyConfig::Composite {
                low_threshold,
                high_threshold,
            } => {
                let config = CompositeConfig {
                    low_threshold: *low_threshold,
                    high_threshold: *high_threshold,
                };
                // Default sub-policies: RoundRobin (distribution) + RoofLine (affinity)
                let distribution: Arc<dyn LoadBalancingPolicy> =
                    Arc::new(RoundRobinPolicy::new());
                let affinity: Arc<dyn LoadBalancingPolicy> =
                    Arc::new(RoofLinePolicy::new());
                Arc::new(CompositePolicy::with_config(
                    distribution,
                    affinity,
                    config,
                ))
            }
        }
    }

    /// Create a policy by name (for dynamic loading)
    pub fn create_by_name(name: &str) -> Option<Arc<dyn LoadBalancingPolicy>> {
        match name.to_lowercase().as_str() {
            "random" => Some(Arc::new(RandomPolicy::new())),
            "round_robin" | "roundrobin" => Some(Arc::new(RoundRobinPolicy::new())),
            "power_of_two" | "poweroftwo" => Some(Arc::new(PowerOfTwoPolicy::new())),
            "cache_aware" | "cacheaware" => Some(Arc::new(CacheAwarePolicy::new())),
            "bucket" => Some(Arc::new(BucketPolicy::new())),
            "manual" => Some(Arc::new(ManualPolicy::new())),
            "consistent_hashing" | "consistenthashing" => {
                Some(Arc::new(ConsistentHashingPolicy::new()))
            }
            "prefix_hash" | "prefixhash" => Some(Arc::new(PrefixHashPolicy::with_defaults())),
            "request_size_bucket" | "requestsizebucket" => {
                Some(Arc::new(RequestSizeBucketPolicy::new()))
            }
            "performance_aware" | "performanceaware" => {
                Some(Arc::new(PerformanceAwarePolicy::new()))
            }
            "request_classification" | "requestclassification" => {
                Some(Arc::new(RequestClassificationPolicy::new()))
            }
            "request_profiling" | "requestprofiling" => {
                Some(Arc::new(RequestProfilingPolicy::new()))
            }
            "roofline" | "roof_line" => {
                Some(Arc::new(RoofLinePolicy::new()))
            }
            "composite" => {
                let distribution: Arc<dyn LoadBalancingPolicy> =
                    Arc::new(RoundRobinPolicy::new());
                let affinity: Arc<dyn LoadBalancingPolicy> =
                    Arc::new(RoofLinePolicy::new());
                Some(Arc::new(CompositePolicy::new(distribution, affinity)))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_create_from_config() {
        let policy = PolicyFactory::create_from_config(&PolicyConfig::Random);
        assert_eq!(policy.name(), "random");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::RoundRobin);
        assert_eq!(policy.name(), "round_robin");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::PowerOfTwo {
            load_check_interval_secs: 60,
        });
        assert_eq!(policy.name(), "power_of_two");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::CacheAware {
            cache_threshold: 0.7,
            balance_abs_threshold: 10,
            balance_rel_threshold: 1.5,
            eviction_interval_secs: 30,
            max_tree_size: 1000,
        });
        assert_eq!(policy.name(), "cache_aware");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::Bucket {
            balance_abs_threshold: 10,
            balance_rel_threshold: 1.5,
            bucket_adjust_interval_secs: 5,
        });
        assert_eq!(policy.name(), "bucket");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::Manual {
            eviction_interval_secs: 60,
            max_idle_secs: 4 * 3600,
            assignment_mode: Default::default(),
        });
        assert_eq!(policy.name(), "manual");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::ConsistentHashing);
        assert_eq!(policy.name(), "consistent_hashing");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::RequestProfiling {
            short_input_threshold: 500,
            long_input_threshold: 4000,
            large_output_threshold: 1024,
        });
        assert_eq!(policy.name(), "request_profiling");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::RequestProfiling {
            short_input_threshold: 200,
            long_input_threshold: 2000,
            large_output_threshold: 512,
        });
        assert_eq!(policy.name(), "request_profiling");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::RoofLine {
            weight_compute: 0.5,
            weight_memory: 0.5,
        });
        assert_eq!(policy.name(), "roofline");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::RoofLine {
            weight_compute: 0.7,
            weight_memory: 0.3,
        });
        assert_eq!(policy.name(), "roofline");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::Composite {
            low_threshold: 0.3,
            high_threshold: 0.7,
        });
        assert_eq!(policy.name(), "composite");

        let policy = PolicyFactory::create_from_config(&PolicyConfig::Composite {
            low_threshold: 0.1,
            high_threshold: 0.5,
        });
        assert_eq!(policy.name(), "composite");
    }

    #[tokio::test]
    async fn test_create_by_name() {
        assert!(PolicyFactory::create_by_name("random").is_some());
        assert!(PolicyFactory::create_by_name("RANDOM").is_some());
        assert!(PolicyFactory::create_by_name("round_robin").is_some());
        assert!(PolicyFactory::create_by_name("RoundRobin").is_some());
        assert!(PolicyFactory::create_by_name("power_of_two").is_some());
        assert!(PolicyFactory::create_by_name("PowerOfTwo").is_some());
        assert!(PolicyFactory::create_by_name("cache_aware").is_some());
        assert!(PolicyFactory::create_by_name("CacheAware").is_some());
        assert!(PolicyFactory::create_by_name("bucket").is_some());
        assert!(PolicyFactory::create_by_name("Bucket").is_some());
        assert!(PolicyFactory::create_by_name("manual").is_some());
        assert!(PolicyFactory::create_by_name("Manual").is_some());
        assert!(PolicyFactory::create_by_name("consistent_hashing").is_some());
        assert!(PolicyFactory::create_by_name("ConsistentHashing").is_some());
        assert!(PolicyFactory::create_by_name("request_profiling").is_some());
        assert!(PolicyFactory::create_by_name("RequestProfiling").is_some());
        assert!(PolicyFactory::create_by_name("roofline").is_some());
        assert!(PolicyFactory::create_by_name("RoofLine").is_some());
        assert!(PolicyFactory::create_by_name("roof_line").is_some());
        assert!(PolicyFactory::create_by_name("composite").is_some());
        assert!(PolicyFactory::create_by_name("Composite").is_some());
        assert!(PolicyFactory::create_by_name("unknown").is_none());
    }
}

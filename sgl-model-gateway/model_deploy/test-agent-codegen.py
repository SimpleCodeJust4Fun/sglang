#!/usr/bin/env python3
"""
Agent 代码生成场景调度测试

测试不同调度策略在代码生成场景（Decode 密集型）的表现。

用法:
    python test-agent-codegen.py              # 运行所有策略测试
    python test-agent-codegen.py --policy round_robin  # 只测试单个策略
    python test-agent-codegen.py --dry-run    # 显示测试计划但不执行
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# ANSI Colors
class C:
    RESET = '\033[0m'
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    DIM = '\033[2m'


# 测试配置
TEST_CONFIGS = [
    {
        "name": "codegen_round_robin",
        "policy": "round_robin",
        "description": "轮询策略：完美负载均衡，无缓存优化"
    },
    {
        "name": "codegen_cache_aware",
        "policy": "cache_aware",
        "description": "缓存感知：利用系统提示词缓存优化"
    },
    {
        "name": "codegen_performance_aware",
        "policy": "performance_aware",
        "description": "性能感知：路由到最优性能 Worker"
    },
    {
        "name": "codegen_power_of_two",
        "policy": "power_of_two",
        "description": "随机二选一：负载均衡与性能的折中"
    },
]


def run_single_test(test_config, prompts_file, num_requests, max_tokens, gateway_url, model):
    """运行单个策略测试"""
    name = test_config["name"]
    policy = test_config["policy"]
    description = test_config["description"]
    
    print(f"\n{C.BLUE}{'='*60}{C.RESET}")
    print(f"{C.BLUE}测试: {name}{C.RESET}")
    print(f"{C.DIM}策略: {policy}{C.RESET}")
    print(f"{C.DIM}说明: {description}{C.RESET}")
    print(f"{C.BLUE}{'='*60}{C.RESET}")
    
    # 构建命令
    script_dir = Path(__file__).parent
    pd_batch_test = script_dir / 'pd-batch-test.py'
    
    cmd = [
        sys.executable, str(pd_batch_test),
        '--num-requests', str(num_requests),
        '--prompts-file', str(prompts_file),
        '--max-tokens', str(max_tokens),
        '--gateway-url', gateway_url,
        '--model', model,
        '--output-dir', f'strategy-results/{name}',
    ]
    
    # pd-batch-test.py 需要知道策略，通过修改启动参数或者环境变量
    # 这里我们假设它会读取环境变量的策略配置
    env = None
    if 'SGX_POLICY' in test_config:
        import os
        env = os.environ.copy()
        env['SGX_POLICY'] = test_config['SGX_POLICY']
    
    print(f"\n{C.CYAN}执行命令:{C.RESET}")
    print(f"  {' '.join(cmd)}")
    print(f"\n{C.YELLOW}开始测试...{C.RESET}\n")
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3600,  # 1 小时超时
            env=env
        )
        
        if result.returncode != 0:
            print(f"{C.RED}测试失败 (exit code {result.returncode}){C.RESET}")
            if result.stderr:
                print(f"{C.DIM}stderr: {result.stderr[:500]}{C.RESET}")
            return None
        
        # 读取结果
        report_path = Path(f"strategy-results/{name}/pd-batch-data.json")
        if report_path.exists():
            with open(report_path) as f:
                report = json.load(f)
            
            summary = report.get('summary', {})
            print(f"\n{C.GREEN}测试完成!{C.RESET}")
            print(f"  成功率: {summary.get('success_rate', 0):.1f}%")
            print(f"  平均延迟: {summary.get('avg_duration', 0):.3f}s")
            print(f"  Prefill 分布: {report.get('prefill_distribution', {})}")
            print(f"  Decode 分布: {report.get('decode_distribution', {})}")
            
            return report
        else:
            print(f"{C.RED}未找到结果文件{C.RESET}")
            return None
            
    except subprocess.TimeoutExpired:
        print(f"{C.RED}测试超时 (超过 1 小时){C.RESET}")
        return None
    except Exception as e:
        print(f"{C.RED}测试异常: {e}{C.RESET}")
        return None


def generate_comparison_report(results):
    """生成对比报告"""
    print(f"\n\n{C.BLUE}{'='*80}{C.RESET}")
    print(f"{C.BLUE}{'Agent 代码生成场景 - 调度策略对比报告':^80}{C.RESET}")
    print(f"{C.BLUE}{'='*80}{C.RESET}\n")
    
    if not results:
        print(f"{C.RED}没有测试结果{C.RESET}")
        return
    
    # 打印表格
    print(f"{'策略':<30} {'成功率':<10} {'平均延迟':<12} {'Prefill分布':<25} {'Decode分布':<25}")
    print('-' * 102)
    
    for name, report in results.items():
        summary = report.get('summary', {})
        success_rate = summary.get('success_rate', 0)
        avg_duration = summary.get('avg_duration', 0)
        prefill_dist = report.get('prefill_distribution', {})
        decode_dist = report.get('decode_distribution', {})
        
        # 格式化分布
        prefill_str = ', '.join([f"{k}:{v}" for k, v in prefill_dist.items()])
        decode_str = ', '.join([f"{k}:{v}" for k, v in decode_dist.items()])
        
        print(f"{name:<30} {success_rate:<10.1f} {avg_duration:<12.3f} {prefill_str:<25} {decode_str:<25}")
    
    print(f"\n{C.GREEN}详细报告已保存至: strategy-results/*/pd-batch-report.html{C.RESET}")


def main():
    parser = argparse.ArgumentParser(description='Agent 代码生成场景调度测试')
    parser.add_argument('--policy', type=str, help='只测试指定策略')
    parser.add_argument('--num-requests', type=int, default=50, help='每个测试的请求数 (默认: 50)')
    parser.add_argument('--prompts-file', type=str, default='prompts/agent_code_gen.txt', 
                       help='Prompts 文件路径')
    parser.add_argument('--max-tokens', type=int, default=500, help='最大生成 tokens (默认: 500)')
    parser.add_argument('--gateway-url', type=str, default='http://127.0.0.1:3000', 
                       help='Gateway URL')
    parser.add_argument('--model', type=str, default='qwen2.5-0.5b-instruct', help='模型名称')
    parser.add_argument('--dry-run', action='store_true', help='显示测试计划但不执行')
    
    args = parser.parse_args()
    
    # 检查 Prompts 文件
    prompts_file = Path(args.prompts_file)
    if not prompts_file.exists():
        print(f"{C.RED}错误: Prompts 文件不存在: {prompts_file}{C.RESET}")
        sys.exit(1)
    
    # 筛选测试策略
    if args.policy:
        configs = [c for c in TEST_CONFIGS if c['policy'] == args.policy]
        if not configs:
            print(f"{C.RED}错误: 未知策略 '{args.policy}'{C.RESET}")
            print(f"可用策略: {', '.join([c['policy'] for c in TEST_CONFIGS])}")
            sys.exit(1)
    else:
        configs = TEST_CONFIGS
    
    # 显示测试计划
    print(f"\n{C.BLUE}{'='*80}{C.RESET}")
    print(f"{C.BLUE}{'Agent 代码生成场景 - 调度优化测试':^80}{C.RESET}")
    print(f"{C.BLUE}{'='*80}{C.RESET}\n")
    print(f"{C.CYAN}测试配置:{C.RESET}")
    print(f"  Prompts 文件: {prompts_file}")
    print(f"  请求数/策略: {args.num_requests}")
    print(f"  最大 tokens: {args.max_tokens}")
    print(f"  Gateway URL: {args.gateway_url}")
    print(f"  测试策略数: {len(configs)}")
    print(f"\n{C.CYAN}待测试策略:{C.RESET}")
    for i, config in enumerate(configs, 1):
        print(f"  {i}. {config['name']:<30} {config['description']}")
    
    if args.dry_run:
        print(f"\n{C.GREEN}Dry run 模式 - 未执行任何测试{C.RESET}")
        return
    
    # 执行测试
    results = {}
    for i, config in enumerate(configs, 1):
        print(f"\n{C.YELLOW}[{i}/{len(configs)}] 开始测试策略: {config['name']}{C.RESET}")
        
        result = run_single_test(
            test_config=config,
            prompts_file=prompts_file,
            num_requests=args.num_requests,
            max_tokens=args.max_tokens,
            gateway_url=args.gateway_url,
            model=args.model
        )
        
        if result:
            results[config['name']] = result
    
    # 生成对比报告
    if results:
        generate_comparison_report(results)
        
        print(f"\n{C.GREEN}{'='*80}{C.RESET}")
        print(f"{C.GREEN}所有测试完成!{C.RESET}")
        print(f"{C.GREEN}{'='*80}{C.RESET}\n")
    else:
        print(f"\n{C.RED}没有成功的测试{C.RESET}")


if __name__ == "__main__":
    main()

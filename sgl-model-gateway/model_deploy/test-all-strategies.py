#!/usr/bin/env python3
"""
Multi-Strategy PD Batch Test Tool

Tests all available scheduling strategies and generates HTML reports
for each strategy in a dedicated output directory.

Usage:
    python3 test-all-strategies.py --num-requests 20 --output-dir strategy-results
"""

import json

import argparse
import json
import os
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
    MAGENTA = '\033[0;35m'
    BOLD = '\033[1m'
    DIM = '\033[2m'

# All available CLI strategies
STRATEGIES = [
    'round_robin',
    'random',
    'power_of_two',
    'cache_aware',
    'prefix_hash',
    'request_size_bucket',
    'performance_aware',
    'request_classification',
]

# Test prompts with varying sizes (expanded for better statistical significance)
TEST_PROMPTS = [
    "Say hello",
    "Hi",
    "What is Python?",
    "Define AI",
    "Explain machine learning in simple terms",
    "How does the internet work? Please describe the key components and protocols",
    "What are the benefits of regular exercise for physical and mental health? Provide a comprehensive answer covering cardiovascular, muscular, and psychological benefits",
    "Describe the process of photosynthesis in plants, including the light-dependent reactions and the Calvin cycle. Explain how chlorophyll captures light energy and converts it into chemical energy stored in glucose molecules",
    "What is artificial intelligence? Discuss the history, current applications, and future prospects of AI. Cover topics including machine learning, deep learning, natural language processing, computer vision, and ethical considerations",
    "How to build a scalable web application from scratch? Provide a detailed guide covering frontend technologies (HTML, CSS, JavaScript, React), backend frameworks (Node.js, Express, Python Flask), database design (SQL vs NoSQL), deployment strategies (Docker, Kubernetes), and performance optimization techniques",
    "Compare and contrast SQL and NoSQL databases. Discuss their data models, query languages, scalability characteristics, consistency guarantees, and use cases. Provide examples of popular databases in each category such as PostgreSQL, MySQL, MongoDB, and Redis",
    "Explain quantum computing in detail. Cover qubits, superposition, entanglement, quantum gates, and quantum algorithms like Shor's algorithm and Grover's algorithm. Discuss the current state of quantum hardware, error correction challenges, and potential applications in cryptography, optimization, and simulation",
    "Write a short story about a robot learning to feel emotions",
    "What is the theory of relativity?",
    "How to cook pasta carbonara",
    "Explain blockchain technology",
    "What are design patterns in software engineering?",
    "Describe the water cycle",
    "What is climate change and its impact?",
    "How does a search engine work?",
]

GATEWAY_URL = "http://127.0.0.1:3000"
MODEL = "qwen2.5-0.5b-instruct"
MAX_TOKENS = 50


def start_gateway(policy):
    """Start Gateway with specified policy."""
    print(f"\n{C.CYAN}{C.BOLD}Starting Gateway with policy: {policy}{C.RESET}")
    
    # Kill existing Gateway
    subprocess.run("killall -9 sgl-model-gateway 2>/dev/null || true", shell=True)
    time.sleep(2)
    
    # Start new Gateway
    cmd = f"""
/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway launch \\
    --pd-disaggregation \\
    --prefill http://127.0.0.1:30000 9000 \\
    --prefill http://127.0.0.1:30001 9001 \\
    --decode http://127.0.0.1:30010 \\
    --decode http://127.0.0.1:30011 \\
    --host 127.0.0.1 \\
    --port 3000 \\
    --policy {policy} \\
    --log-level info \\
    > /tmp/sgl-gateway-test.log 2>&1 &
"""
    subprocess.run(cmd, shell=True)
    
    # Wait for Gateway to start
    print(f"  Waiting for Gateway...", end='', flush=True)
    for i in range(30):
        result = subprocess.run(
            f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 2 {GATEWAY_URL}/health",
            shell=True, capture_output=True, text=True
        )
        if '200' in result.stdout:
            print(f" {C.GREEN}Ready!{C.RESET}")
            time.sleep(3)  # Extra wait for worker discovery
            return True
        time.sleep(1)
        print(".", end='', flush=True)
    
    print(f" {C.RED}Failed!{C.RESET}")
    return False


def run_batch_test(strategy, num_requests, output_dir):
    """Run batch test for a specific strategy."""
    print(f"\n{C.MAGENTA}{C.BOLD}{'='*60}{C.RESET}")
    print(f"{C.MAGENTA}{C.BOLD}Testing Strategy: {strategy}{C.RESET}")
    print(f"{C.MAGENTA}{C.BOLD}{'='*60}{C.RESET}")
    
    # Start Gateway
    if not start_gateway(strategy):
        print(f"{C.RED}Failed to start Gateway for strategy: {strategy}{C.RESET}")
        return False
    
    # Create output directory for this strategy
    strategy_dir = output_dir / strategy
    strategy_dir.mkdir(parents=True, exist_ok=True)
    
    # Run pd-batch-test.py
    script_dir = Path(__file__).parent
    batch_test = script_dir / 'pd-batch-test.py'
    
    output_html = strategy_dir / 'pd-batch-report.html'
    output_json = strategy_dir / 'pd-batch-data.json'
    
    # Create a temporary prompts file with varied prompts
    prompts_file = strategy_dir / 'prompts.txt'
    # Cycle through TEST_PROMPTS to get num_requests prompts
    prompts = [TEST_PROMPTS[i % len(TEST_PROMPTS)] for i in range(num_requests)]
    with open(prompts_file, 'w') as f:
        f.write('\n'.join(prompts))
    
    cmd = [
        sys.executable, str(batch_test),
        '--num-requests', str(num_requests),
        '--gateway-url', GATEWAY_URL,
        '--model', MODEL,
        '--max-tokens', str(MAX_TOKENS),
        '--prompts-file', str(prompts_file),
        '--output', str(output_html),
        '--json-output', str(output_json),
    ]
    
    print(f"\n{C.CYAN}Running {num_requests} requests...{C.RESET}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=num_requests * 120)
    
    if result.returncode != 0:
        print(f"{C.RED}Batch test failed for {strategy}{C.RESET}")
        print(result.stderr[-500:] if len(result.stderr) > 500 else result.stderr)
        return False
    
    # Show summary
    for line in result.stdout.split('\n'):
        if any(kw in line for kw in ['Total Requests', 'Successful', 'Failed', 'Distribution', '→', 'prefill-', 'decode-']):
            print(f"  {line}")
    
    print(f"\n{C.GREEN}Report saved to: {output_html}{C.RESET}")
    return True


def generate_index(output_dir, strategies, results, num_requests):
    """Generate index.html with links to all strategy reports."""
    index_file = output_dir / 'index.html'
    
    # Load JSON data for each strategy
    strategy_data = {}
    for strategy in strategies:
        json_file = output_dir / strategy / 'pd-batch-data.json'
        if json_file.exists():
            with open(json_file, 'r') as f:
                strategy_data[strategy] = json.load(f)
        else:
            strategy_data[strategy] = None
    
    # Strategy descriptions
    strategy_info = {
        'round_robin': '轮询策略：按固定顺序循环分配请求，确保均匀分布',
        'random': '随机策略：随机选择worker，大致均衡但有波动',
        'power_of_two': '随机二选一：随机选2个worker，选负载较低的',
        'cache_aware': '缓存感知：根据KV Cache前缀匹配路由',
        'prefix_hash': '前缀哈希：基于请求内容哈希路由',
        'request_size_bucket': '请求长度分桶：按prompt长度路由到不同worker',
        'performance_aware': '性能感知：选择性能指标最优的worker',
        'request_classification': '请求分类：按请求类型分类路由',
    }
    
    # Build HTML
    rows = ''
    for strategy in strategies:
        status = results.get(strategy, 'N/A')
        status_color = '#28a745' if status == 'PASS' else '#dc3545'
        data = strategy_data.get(strategy)
        
        if data:
            summary = data.get('summary', {})
            prefill_dist = data.get('prefill_distribution', {})
            decode_dist = data.get('decode_distribution', {})
            pairs = data.get('worker_pairs', {})
            
            prefill_str = ', '.join([f'{k}:{v}' for k, v in prefill_dist.items()])
            decode_str = ', '.join([f'{k}:{v}' for k, v in decode_dist.items()])
            pair_str = ', '.join([f'{k}:{v}' for k, v in pairs.items()])
            
            rows += f'''
            <tr>
                <td><a href="{strategy}/pd-batch-report.html">{strategy}</a></td>
                <td>{strategy_info.get(strategy, '')}</td>
                <td><span class="badge" style="background:{status_color}">{status}</span></td>
                <td>{summary.get('total_requests', 0)}</td>
                <td>{summary.get('success_rate', 0)}%</td>
                <td>{summary.get('avg_duration', 0):.3f}s</td>
                <td>{prefill_str}</td>
                <td>{decode_str}</td>
                <td>{pair_str}</td>
                <td><a href="{strategy}/pd-batch-data.json" class="json-link">JSON</a></td>
            </tr>'''
        else:
            rows += f'''
            <tr>
                <td><a href="{strategy}/pd-batch-report.html">{strategy}</a></td>
                <td>{strategy_info.get(strategy, '')}</td>
                <td><span class="badge" style="background:{status_color}">{status}</span></td>
                <td colspan="6">Data not available</td>
                <td>-</td>
            </tr>'''
    
    html = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PD调度策略测试报告</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #f5f7fa;
            color: #333;
            padding: 30px;
        }}
        .container {{ max-width: 1600px; margin: 0 auto; }}
        h1 {{
            text-align: center;
            color: #2c3e50;
            margin-bottom: 10px;
            font-size: 2em;
        }}
        .subtitle {{
            text-align: center;
            color: #7f8c8d;
            margin-bottom: 30px;
        }}
        .summary-cards {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }}
        .card {{
            background: white;
            border-radius: 8px;
            padding: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            text-align: center;
        }}
        .card .value {{ font-size: 2em; font-weight: bold; color: #3498db; }}
        .card .label {{ color: #7f8c8d; font-size: 0.9em; }}
        table {{
            width: 100%;
            border-collapse: collapse;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }}
        th {{
            background: #3498db;
            color: white;
            padding: 12px 10px;
            text-align: left;
            font-size: 0.85em;
        }}
        td {{
            padding: 12px 10px;
            border-bottom: 1px solid #eee;
            font-size: 0.85em;
        }}
        tr:hover {{ background: #f8f9fa; }}
        .badge {{
            display: inline-block;
            padding: 3px 10px;
            border-radius: 12px;
            color: white;
            font-size: 0.8em;
            font-weight: bold;
        }}
        a {{ color: #3498db; text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
        .json-link {{ color: #28a745; font-weight: bold; }}
        .timestamp {{
            text-align: center;
            color: #7f8c8d;
            margin-top: 20px;
            font-size: 0.85em;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>PD调度策略测试报告</h1>
        <p class="subtitle">每个策略 {num_requests} 条请求 | 8种策略对比分析</p>
        
        <div class="summary-cards">
            <div class="card">
                <div class="value">{len(strategies)}</div>
                <div class="label">测试策略数</div>
            </div>
            <div class="card">
                <div class="value">{num_requests}</div>
                <div class="label">每策略请求数</div>
            </div>
            <div class="card">
                <div class="value">{len(strategies) * num_requests}</div>
                <div class="label">总请求数</div>
            </div>
            <div class="card">
                <div class="value">{sum(1 for s in results.values() if s == 'PASS')}</div>
                <div class="label">通过策略数</div>
            </div>
        </div>
        
        <table>
            <thead>
                <tr>
                    <th>策略名称</th>
                    <th>策略说明</th>
                    <th>状态</th>
                    <th>请求数</th>
                    <th>成功率</th>
                    <th>平均延迟</th>
                    <th>Prefill分布</th>
                    <th>Decode分布</th>
                    <th>Worker对</th>
                    <th>数据</th>
                </tr>
            </thead>
            <tbody>
                {rows}
            </tbody>
        </table>
        
        <p class="timestamp">生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    </div>
</body>
</html>'''
    
    with open(index_file, 'w') as f:
        f.write(html)
    
    return index_file


def main():
    parser = argparse.ArgumentParser(description='Multi-Strategy PD Batch Test Tool')
    parser.add_argument('--num-requests', '-n', type=int, default=10, help='Number of requests per strategy')
    parser.add_argument('--output-dir', '-o', default='strategy-results', help='Output directory')
    parser.add_argument('--strategies', nargs='+', choices=STRATEGIES, help='Specific strategies to test (default: all)')
    args = parser.parse_args()
    
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    strategies_to_test = args.strategies or STRATEGIES
    
    print(f"\n{C.BOLD}{C.CYAN}{'='*60}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}Multi-Strategy PD Batch Test{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'='*60}{C.RESET}")
    print(f"  Strategies: {', '.join(strategies_to_test)}")
    print(f"  Requests per strategy: {args.num_requests}")
    print(f"  Output directory: {output_dir}")
    print(f"  Gateway URL: {GATEWAY_URL}")
    print(f"  Model: {MODEL}")
    print()
    
    results = {}
    for i, strategy in enumerate(strategies_to_test, 1):
        print(f"\n{C.BOLD}[{i}/{len(strategies_to_test)}]{C.RESET}", end=' ')
        success = run_batch_test(strategy, args.num_requests, output_dir)
        results[strategy] = 'PASS' if success else 'FAIL'
    
    # Summary
    print(f"\n\n{C.BOLD}{C.CYAN}{'='*60}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}Test Summary{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'='*60}{C.RESET}")
    
    for strategy, status in results.items():
        color = C.GREEN if status == 'PASS' else C.RED
        print(f"  {strategy:30s} {color}{status}{C.RESET}")
    
    print(f"\n{C.GREEN}All reports saved to: {output_dir}/{C.RESET}")
    
    # Generate index.html
    index_file = generate_index(output_dir, strategies_to_test, results, args.num_requests)
    print(f"\n{C.CYAN}Navigation index: {index_file}{C.RESET}")
    print(f"{C.YELLOW}Open index.html in browser to view all strategy reports{C.RESET}")


if __name__ == '__main__':
    main()

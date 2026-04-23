#!/usr/bin/env python3
"""
PD Batch Test & Report Tool

Calls pd-test.py multiple times and generates an HTML report
with scheduling distribution analysis and charts.

Usage:
    python3 pd-batch-test.py --num-requests 10
    python3 pd-batch-test.py -n 20 --gateway-url http://127.0.0.1:3000
    python3 pd-batch-test.py --prompts-file prompts.txt --output report.html
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from collections import Counter

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


def run_pd_test(prompt, gateway_url, model, max_tokens, verbose=False):
    """Run pd-test.py with --json mode and return parsed results."""
    script_dir = Path(__file__).parent
    pd_test = script_dir / 'pd-test.py'
    
    if not pd_test.exists():
        print(f"{C.RED}Error: pd-test.py not found at {pd_test}{C.RESET}")
        return None
    
    cmd = [
        sys.executable, str(pd_test),
        prompt,
        '--gateway-url', gateway_url,
        '--model', model,
        '--max-tokens', str(max_tokens),
        '--json',
        '--no-response',  # Skip showing response content in console
    ]
    
    if verbose:
        cmd.append('-v')
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120
        )
        
        # Debug output if failed
        if result.returncode != 0:
            print(f"{C.RED}pd-test.py failed (exit code {result.returncode}): {result.stderr[:200]}{C.RESET}")
            if result.stdout:
                print(f"{C.DIM}stdout: {result.stdout[:200]}{C.RESET}")
            return None
        
        # Parse JSON output
        output = result.stdout.strip()
        if not output:
            if result.stderr:
                print(f"{C.RED}pd-test.py returned empty stdout. stderr: {result.stderr[:200]}{C.RESET}")
            return None
        
        try:
            results = json.loads(output)
        except json.JSONDecodeError as e:
            print(f"{C.RED}JSON parse error: {e}{C.RESET}")
            print(f"{C.DIM}Output was: {output[:500]}{C.RESET}")
            return None
        return results if results else None
        
    except subprocess.TimeoutExpired:
        print(f"{C.RED}Request timed out{C.RESET}")
        return None
    except Exception as e:
        print(f"{C.RED}Error running pd-test.py: {e}{C.RESET}")
        return None


def analyze_scheduling(all_results):
    """Analyze scheduling distribution from batch results."""
    stats = {
        'total_requests': len(all_results),
        'successful': 0,
        'failed': 0,
        'prefill_distribution': Counter(),
        'decode_distribution': Counter(),
        'worker_pairs': Counter(),
        'durations': [],
        'prompt_tokens': [],
        'completion_tokens': [],
        'requests_detail': [],
    }
    
    for result in all_results:
        if not result:
            stats['failed'] += 1
            continue
        
        stats['successful'] += 1
        
        # Extract gateway routing info
        gw = result.get('gateway', {})
        prefill_name = gw.get('prefill_name', 'unknown')
        decode_name = gw.get('decode_name', 'unknown')
        
        stats['prefill_distribution'][prefill_name] += 1
        stats['decode_distribution'][decode_name] += 1
        stats['worker_pairs'][f"{prefill_name} → {decode_name}"] += 1
        
        # Collect metrics
        if result.get('duration'):
            stats['durations'].append(result['duration'])
        if result.get('prompt_tokens'):
            stats['prompt_tokens'].append(result['prompt_tokens'])
        if result.get('completion_tokens'):
            stats['completion_tokens'].append(result['completion_tokens'])
        
        # Store request detail
        stats['requests_detail'].append({
            'request_id': result.get('request_id'),
            'prefill': prefill_name,
            'decode': decode_name,
            'duration': result.get('duration'),
            'prompt_tokens': result.get('prompt_tokens'),
            'completion_tokens': result.get('completion_tokens'),
            'success': result.get('success', False),
            'raw': result,
        })
    
    return stats


def generate_html_report(stats, output_path):
    """Generate an HTML report with charts and statistics."""
    
    # Calculate summary statistics
    total = stats['total_requests']
    success = stats['successful']
    failed = stats['failed']
    success_rate = (success / total * 100) if total > 0 else 0
    
    avg_duration = sum(stats['durations']) / len(stats['durations']) if stats['durations'] else 0
    min_duration = min(stats['durations']) if stats['durations'] else 0
    max_duration = max(stats['durations']) if stats['durations'] else 0
    
    avg_prompt = sum(stats['prompt_tokens']) / len(stats['prompt_tokens']) if stats['prompt_tokens'] else 0
    avg_completion = sum(stats['completion_tokens']) / len(stats['completion_tokens']) if stats['completion_tokens'] else 0
    
    # Prepare chart data
    prefill_labels = list(stats['prefill_distribution'].keys())
    prefill_counts = list(stats['prefill_distribution'].values())
    
    decode_labels = list(stats['decode_distribution'].keys())
    decode_counts = list(stats['decode_distribution'].values())
    
    pair_labels = list(stats['worker_pairs'].keys())
    pair_counts = list(stats['worker_pairs'].values())
    
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PD Batch Test Report</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: #f5f7fa;
            color: #333;
            padding: 20px;
        }}
        
        .container {{
            max-width: 1400px;
            margin: 0 auto;
        }}
        
        h1 {{
            text-align: center;
            color: #2c3e50;
            margin-bottom: 30px;
            font-size: 2.5em;
        }}
        
        .summary {{
            background: white;
            border-radius: 10px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }}
        
        .summary h2 {{
            color: #34495e;
            margin-bottom: 20px;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
        }}
        
        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }}
        
        .stat-card {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
        }}
        
        .stat-card.success {{
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
        }}
        
        .stat-card.error {{
            background: linear-gradient(135deg, #eb3349 0%, #f45c43 100%);
        }}
        
        .stat-card.info {{
            background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
        }}
        
        .stat-value {{
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }}
        
        .stat-label {{
            font-size: 0.9em;
            opacity: 0.9;
        }}
        
        .charts {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 30px;
            margin-bottom: 30px;
        }}
        
        .chart-container {{
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }}
        
        .chart-container h3 {{
            color: #34495e;
            margin-bottom: 15px;
            text-align: center;
        }}
        
        .chart-wrapper {{
            position: relative;
            height: 300px;
        }}
        
        .requests-section {{
            background: white;
            border-radius: 10px;
            padding: 30px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }}
        
        .requests-section h2 {{
            color: #34495e;
            margin-bottom: 20px;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
        }}
        
        .request-item {{
            border: 1px solid #e0e0e0;
            border-radius: 5px;
            margin-bottom: 10px;
            overflow: hidden;
        }}
        
        .request-header {{
            background: #f8f9fa;
            padding: 15px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.2s;
        }}
        
        .request-header:hover {{
            background: #e9ecef;
        }}
        
        .request-header.success {{
            border-left: 4px solid #28a745;
        }}
        
        .request-header.failed {{
            border-left: 4px solid #dc3545;
        }}
        
        .request-info {{
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
        }}
        
        .request-info span {{
            font-size: 0.9em;
        }}
        
        .request-info .label {{
            color: #6c757d;
            font-weight: bold;
        }}
        
        .request-detail {{
            display: none;
            padding: 15px;
            background: #f8f9fa;
            border-top: 1px solid #e0e0e0;
        }}
        
        .request-detail.active {{
            display: block;
        }}
        
        .json-output {{
            background: #2d2d2d;
            color: #f8f8f2;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.85em;
            line-height: 1.5;
        }}
        
        .timestamp {{
            text-align: center;
            color: #7f8c8d;
            margin-top: 30px;
            font-size: 0.9em;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>PD Batch Test Report</h1>
        
        <div class="summary">
            <h2>Summary Statistics</h2>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-value">{total}</div>
                    <div class="stat-label">Total Requests</div>
                </div>
                <div class="stat-card success">
                    <div class="stat-value">{success}</div>
                    <div class="stat-label">Successful</div>
                </div>
                <div class="stat-card error">
                    <div class="stat-value">{failed}</div>
                    <div class="stat-label">Failed</div>
                </div>
                <div class="stat-card info">
                    <div class="stat-value">{success_rate:.1f}%</div>
                    <div class="stat-label">Success Rate</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">{avg_duration:.2f}s</div>
                    <div class="stat-label">Avg Duration</div>
                </div>
                <div class="stat-card info">
                    <div class="stat-value">{min_duration:.2f}s / {max_duration:.2f}s</div>
                    <div class="stat-label">Min / Max Duration</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">{avg_prompt:.0f}</div>
                    <div class="stat-label">Avg Prompt Tokens</div>
                </div>
                <div class="stat-card info">
                    <div class="stat-value">{avg_completion:.0f}</div>
                    <div class="stat-label">Avg Completion Tokens</div>
                </div>
            </div>
        </div>
        
        <div class="charts">
            <div class="chart-container">
                <h3>Prefill Worker Distribution</h3>
                <div class="chart-wrapper">
                    <canvas id="prefillChart"></canvas>
                </div>
            </div>
            
            <div class="chart-container">
                <h3>Decode Worker Distribution</h3>
                <div class="chart-wrapper">
                    <canvas id="decodeChart"></canvas>
                </div>
            </div>
            
            <div class="chart-container">
                <h3>Worker Pair Distribution</h3>
                <div class="chart-wrapper">
                    <canvas id="pairChart"></canvas>
                </div>
            </div>
            
            <div class="chart-container">
                <h3>Request Duration Distribution</h3>
                <div class="chart-wrapper">
                    <canvas id="durationChart"></canvas>
                </div>
            </div>
        </div>
        
        <div class="requests-section">
            <h2>Request Details</h2>
            <p style="color: #7f8c8d; margin-bottom: 15px;">Click on a request to view its full JSON output</p>
"""
    
    # Add request items
    for idx, req in enumerate(stats['requests_detail']):
        status_class = 'success' if req['success'] else 'failed'
        status_text = '✓' if req['success'] else '✗'
        
        html_content += f"""
            <div class="request-item">
                <div class="request-header {status_class}" onclick="toggleRequest({idx})">
                    <div class="request-info">
                        <span><span class="label">#{idx + 1}</span> {status_text}</span>
                        <span><span class="label">Prefill:</span> {req['prefill']}</span>
                        <span><span class="label">Decode:</span> {req['decode']}</span>
                        <span><span class="label">Duration:</span> {req['duration']:.2f}s</span>
                        <span><span class="label">Tokens:</span> {req['prompt_tokens']} → {req['completion_tokens']}</span>
                    </div>
                </div>
                <div class="request-detail" id="request-{idx}">
                    <div class="json-output"><pre>{json.dumps(req['raw'], indent=2, ensure_ascii=False)}</pre></div>
                </div>
            </div>
"""
    
    # Close HTML and add chart scripts
    html_content += f"""
        </div>
        
        <div class="timestamp">
            Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
        </div>
    </div>
    
    <script>
        function toggleRequest(idx) {{
            const detail = document.getElementById('request-' + idx);
            detail.classList.toggle('active');
        }}
        
        // Chart.js configuration
        const colors = [
            'rgba(255, 99, 132, 0.7)',
            'rgba(54, 162, 235, 0.7)',
            'rgba(255, 206, 86, 0.7)',
            'rgba(75, 192, 192, 0.7)',
            'rgba(153, 102, 255, 0.7)',
            'rgba(255, 159, 64, 0.7)',
            'rgba(199, 199, 199, 0.7)',
            'rgba(83, 102, 255, 0.7)',
        ];
        
        const borderColors = colors.map(c => c.replace('0.7', '1'));
        
        // Prefill Worker Chart
        new Chart(document.getElementById('prefillChart'), {{
            type: 'pie',
            data: {{
                labels: {json.dumps(prefill_labels)},
                datasets: [{{
                    data: {json.dumps(prefill_counts)},
                    backgroundColor: colors.slice(0, {len(prefill_labels)}),
                    borderColor: borderColors.slice(0, {len(prefill_labels)}),
                    borderWidth: 2
                }}]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{
                        position: 'bottom'
                    }}
                }}
            }}
        }});
        
        // Decode Worker Chart
        new Chart(document.getElementById('decodeChart'), {{
            type: 'pie',
            data: {{
                labels: {json.dumps(decode_labels)},
                datasets: [{{
                    data: {json.dumps(decode_counts)},
                    backgroundColor: colors.slice(0, {len(decode_labels)}),
                    borderColor: borderColors.slice(0, {len(decode_labels)}),
                    borderWidth: 2
                }}]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{
                        position: 'bottom'
                    }}
                }}
            }}
        }});
        
        // Worker Pair Chart
        new Chart(document.getElementById('pairChart'), {{
            type: 'bar',
            data: {{
                labels: {json.dumps(pair_labels)},
                datasets: [{{
                    label: 'Request Count',
                    data: {json.dumps(pair_counts)},
                    backgroundColor: colors.slice(0, {len(pair_labels)}),
                    borderColor: borderColors.slice(0, {len(pair_labels)}),
                    borderWidth: 1
                }}]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{
                        display: false
                    }}
                }},
                scales: {{
                    y: {{
                        beginAtZero: true,
                        ticks: {{
                            stepSize: 1
                        }}
                    }}
                }}
            }}
        }});
        
        // Duration Distribution Chart
        const durations = {json.dumps(stats['durations'])};
        const bins = 10;
        const minDur = Math.min(...durations);
        const maxDur = Math.max(...durations);
        const binWidth = (maxDur - minDur) / bins;
        const histogram = new Array(bins).fill(0);
        
        durations.forEach(d => {{
            const binIdx = Math.min(Math.floor((d - minDur) / binWidth), bins - 1);
            histogram[binIdx]++;
        }});
        
        const binLabels = [];
        for (let i = 0; i < bins; i++) {{
            const start = minDur + i * binWidth;
            const end = start + binWidth;
            binLabels.push(`${{start.toFixed(2)}}s - ${{end.toFixed(2)}}s`);
        }}
        
        new Chart(document.getElementById('durationChart'), {{
            type: 'bar',
            data: {{
                labels: binLabels,
                datasets: [{{
                    label: 'Request Count',
                    data: histogram,
                    backgroundColor: 'rgba(54, 162, 235, 0.7)',
                    borderColor: 'rgba(54, 162, 235, 1)',
                    borderWidth: 1
                }}]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{
                        display: false
                    }}
                }},
                scales: {{
                    y: {{
                        beginAtZero: true,
                        ticks: {{
                            stepSize: 1
                        }}
                    }}
                }}
            }}
        }});
    </script>
</body>
</html>
"""
    
    # Write HTML file
    output_file = Path(output_path)
    output_file.write_text(html_content, encoding='utf-8')
    return str(output_file)


def main():
    parser = argparse.ArgumentParser(description='PD Batch Test & Report Tool')
    parser.add_argument('--num-requests', '-n', type=int, default=10,
                       help='Number of requests to send')
    parser.add_argument('--prompts-file', '-f',
                       help='File with prompts (one per line). If not specified, uses default prompts')
    parser.add_argument('--prompt', '-p',
                       help='Single prompt to use for all requests')
    parser.add_argument('--gateway-url', default='http://127.0.0.1:3000',
                       help='Gateway URL')
    parser.add_argument('--model', default='qwen2.5-0.5b-instruct',
                       help='Model name')
    parser.add_argument('--max-tokens', type=int, default=50,
                       help='Max tokens to generate')
    parser.add_argument('--output', '-o', default='pd-batch-report.html',
                       help='Output HTML report file')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Verbose output')
    args = parser.parse_args()
    
    print(f"{C.BOLD}{C.CYAN}PD Batch Test & Report Tool{C.RESET}")
    print(f"{C.DIM}Gateway: {args.gateway_url} | Model: {args.model}{C.RESET}")
    print(f"{C.DIM}Requests: {args.num_requests} | Output: {args.output}{C.RESET}")
    print()
    
    # Prepare prompts
    prompts = []
    if args.prompts_file:
        with open(args.prompts_file, 'r') as f:
            prompts = [line.strip() for line in f if line.strip()]
        # If fewer prompts than requests, cycle through them
        while len(prompts) < args.num_requests:
            prompts.extend(prompts)
        prompts = prompts[:args.num_requests]
    elif args.prompt:
        prompts = [args.prompt] * args.num_requests
    else:
        # Default prompts
        default_prompts = [
            "What is Python programming language?",
            "Explain the concept of machine learning",
            "How does the internet work?",
            "What are the benefits of exercise?",
            "Describe the process of photosynthesis",
            "What is artificial intelligence?",
            "How to write a simple web application?",
            "What is the difference between SQL and NoSQL databases?",
            "Explain quantum computing in simple terms",
            "What are the best practices for code review?",
        ]
        prompts = (default_prompts * ((args.num_requests // len(default_prompts)) + 1))[:args.num_requests]
    
    # Run batch tests
    all_results = []
    print(f"{C.BOLD}Running {args.num_requests} requests...{C.RESET}")
    
    for i, prompt in enumerate(prompts):
        print(f"\n{C.YELLOW}[{i+1}/{args.num_requests}] Testing: {prompt[:60]}{'...' if len(prompt) > 60 else ''}{C.RESET}")
        
        result = run_pd_test(
            prompt,
            args.gateway_url,
            args.model,
            args.max_tokens,
            args.verbose
        )
        
        if result and len(result) > 0:
            req_result = result[0]
            status = f"{C.GREEN}OK{C.RESET}" if req_result.get('success') else f"{C.RED}FAIL{C.RESET}"
            duration = req_result.get('duration', 0)
            prefill = req_result.get('gateway', {}).get('prefill_name', 'N/A')
            decode = req_result.get('gateway', {}).get('decode_name', 'N/A')
            print(f"  {C.CYAN}Status:{C.RESET} {status}, {C.CYAN}Duration:{C.RESET} {duration:.2f}s, {C.CYAN}Routing:{C.RESET} P={prefill}, D={decode}")
            all_results.append(req_result)
        else:
            print(f"  {C.RED}Failed to get result{C.RESET}")
            all_results.append(None)
    
    # Analyze scheduling
    print(f"\n{C.BOLD}{C.CYAN}Analyzing scheduling distribution...{C.RESET}")
    stats = analyze_scheduling(all_results)
    
    # Print summary
    print(f"\n{C.BOLD}Summary:{C.RESET}")
    print(f"  Total Requests: {stats['total_requests']}")
    print(f"  Successful: {stats['successful']}")
    print(f"  Failed: {stats['failed']}")
    
    if stats['prefill_distribution']:
        print(f"\n{C.BOLD}Prefill Worker Distribution:{C.RESET}")
        for worker, count in stats['prefill_distribution'].most_common():
            print(f"  {worker}: {count}")
    
    if stats['decode_distribution']:
        print(f"\n{C.BOLD}Decode Worker Distribution:{C.RESET}")
        for worker, count in stats['decode_distribution'].most_common():
            print(f"  {worker}: {count}")
    
    if stats['worker_pairs']:
        print(f"\n{C.BOLD}Worker Pair Distribution:{C.RESET}")
        for pair, count in stats['worker_pairs'].most_common():
            print(f"  {pair}: {count}")
    
    # Generate HTML report
    print(f"\n{C.BOLD}{C.GREEN}Generating HTML report...{C.RESET}")
    output_file = generate_html_report(stats, args.output)
    print(f"{C.GREEN}Report saved to: {output_file}{C.RESET}")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
Generate Comprehensive Benchmark Report

Reads all benchmark results from benchmark-results/ directory
and generates a comprehensive HTML report.
"""

import json
import sys
import os
from datetime import datetime
from pathlib import Path
from typing import Dict, List


def load_jsonl_results(file_path: str) -> Dict:
    """Load last line from JSONL file (latest benchmark run)"""
    try:
        with open(file_path, 'r') as f:
            lines = f.readlines()
            if not lines:
                return None
            return json.loads(lines[-1])
    except Exception as e:
        print(f"Error loading {file_path}: {e}")
        return None


def discover_results(results_dir: str) -> List[Dict]:
    """Discover all benchmark result files"""
    results = []
    results_path = Path(results_dir)
    
    if not results_path.exists():
        print(f"Results directory not found: {results_dir}")
        return results
    
    for jsonl_file in sorted(results_path.glob("bench_*.jsonl")):
        data = load_jsonl_results(str(jsonl_file))
        if data:
            data['_filename'] = jsonl_file.name
            results.append(data)
    
    return results


def generate_report(results: List[Dict], output_path: str):
    """Generate comprehensive HTML report"""
    
    if not results:
        print("No benchmark results found!")
        return
    
    # Sort by strategy name
    results.sort(key=lambda x: x.get('_filename', ''))
    
    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SGLang PD 分离策略 - 综合性能测试报告</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.2/dist/chart.umd.min.js"></script>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #f5f7fa;
            min-height: 100vh;
            padding: 20px;
        }}
        .container {{ max-width: 1600px; margin: 0 auto; }}
        h1 {{
            text-align: center;
            color: white;
            margin-bottom: 10px;
            font-size: 2.5em;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }}
        .subtitle {{
            text-align: center;
            color: rgba(255,255,255,0.9);
            margin-bottom: 30px;
            font-size: 1.1em;
        }}
        .config-card {{
            background: white;
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        .config-card h3 {{
            color: #2c3e50;
            margin-bottom: 15px;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }}
        .config-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 15px;
        }}
        .config-item {{
            background: #f8f9fa;
            padding: 12px;
            border-radius: 8px;
            text-align: center;
        }}
        .config-label {{ font-size: 0.85em; color: #6c757d; }}
        .config-value {{ font-size: 1.1em; font-weight: bold; color: #2c3e50; }}
        .strategies {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 30px;
            margin-bottom: 30px;
        }}
        .strategy-card {{
            background: white;
            border-radius: 12px;
            padding: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            position: relative;
            overflow: hidden;
        }}
        .strategy-card::before {{
            content: '';
            position: absolute;
            top: 0; left: 0; right: 0;
            height: 6px;
            background: #667eea;
        }}
        .strategy-card:nth-child(2)::before {{
            background: #f093fb;
        }}
        .strategy-card:nth-child(3)::before {{
            background: #4facfe;
        }}
        .strategy-title {{
            font-size: 1.6em;
            color: #2c3e50;
            margin-bottom: 20px;
            text-align: center;
        }}
        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 12px;
        }}
        .stat-card {{
            background: #667eea;
            color: white;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
        }}
        .stat-card:nth-child(2) {{
            background: #764ba2;
        }}
        .stat-card:nth-child(3) {{
            background: #f093fb;
        }}
        .stat-card:nth-child(4) {{
            background: #4facfe;
        }}
        .stat-card:nth-child(5) {{
            background: #11998e;
        }}
        .stat-card:nth-child(6) {{
            background: #fc5c7d;
        }}
        .stat-value {{ font-size: 1.8em; font-weight: bold; margin-bottom: 5px; }}
        .stat-label {{ font-size: 0.8em; opacity: 0.9; }}
        .charts {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(500px, 1fr));
            gap: 30px;
            margin-bottom: 30px;
        }}
        .chart-container {{
            background: white;
            border-radius: 12px;
            padding: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        .chart-container h3 {{
            color: #2c3e50;
            margin-bottom: 15px;
            text-align: center;
        }}
        .chart-wrapper {{ position: relative; height: 350px; }}
        .comparison-table {{
            background: white;
            border-radius: 12px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            overflow-x: auto;
        }}
        .comparison-table h2 {{
            color: #2c3e50;
            margin-bottom: 20px;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            font-size: 0.9em;
        }}
        th, td {{
            padding: 12px 8px;
            text-align: center;
            border-bottom: 1px solid #dee2e6;
        }}
        th {{
            background: #f8f9fa;
            font-weight: bold;
            color: #2c3e50;
        }}
        tr:hover {{ background: #f8f9fa; }}
        .winner {{ color: #28a745; font-weight: bold; }}
        .note-box {{
            background: #fff3cd;
            border-left: 4px solid #ffc107;
            padding: 15px;
            margin-top: 20px;
            border-radius: 4px;
        }}
        .note-box h4 {{ color: #856404; margin-bottom: 10px; }}
        .note-box p {{ color: #856404; font-size: 0.9em; line-height: 1.6; }}
        .timestamp {{
            text-align: center;
            color: rgba(255,255,255,0.8);
            margin-top: 30px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>SGLang PD 分离策略 - 综合性能测试</h1>
        <div class="subtitle">所有调度策略性能对比报告</div>
        
        <div class="config-card">
            <h3>测试配置</h3>
            <div class="config-grid">
                <div class="config-item">
                    <div class="config-label">模型</div>
                    <div class="config-value">Qwen2.5-0.5B-GPTQ-Int4</div>
                </div>
                <div class="config-item">
                    <div class="config-label">GPU</div>
                    <div class="config-value">RTX 4070 Ti SUPER 16GB</div>
                </div>
                <div class="config-item">
                    <div class="config-label">Workers</div>
                    <div class="config-value">6 (4P+2D)</div>
                </div>
                <div class="config-item">
                    <div class="config-label">Context Length</div>
                    <div class="config-value">512 tokens</div>
                </div>
                <div class="config-item">
                    <div class="config-label">数据集</div>
                    <div class="config-value">ShareGPT V3</div>
                </div>
                <div class="config-item">
                    <div class="config-label">测试工具</div>
                    <div class="config-value">sglang.bench_serving</div>
                </div>
            </div>
        </div>
        
        <div class="strategies">
"""
    
    # Generate strategy cards
    colors = ['#667eea', '#f093fb', '#4facfe', '#11998e', '#f7971e', '#fc5c7d']
    
    for idx, result in enumerate(results):
        strategy_name = result.get('_filename', 'Unknown').replace('bench_', '').replace('.jsonl', '')
        color = colors[idx % len(colors)]
        
        ttft_mean = result.get('mean_ttft_ms', 0)
        ttft_median = result.get('median_ttft_ms', 0)
        ttft_p99 = result.get('p99_ttft_ms', 0)
        e2e_mean = result.get('mean_e2e_latency_ms', 0)
        e2e_median = result.get('median_e2e_latency_ms', 0)
        req_throughput = result.get('request_throughput', 0)
        total_throughput = result.get('total_throughput', 0)
        completed = result.get('completed', 0)
        max_concurrent = result.get('max_concurrent_requests', 0)
        
        html += f"""
            <div class="strategy-card">
                <div class="strategy-title">{strategy_name.replace('_', ' ').title()}</div>
                <div class="stats-grid">
                    <div class="stat-card">
                        <div class="stat-value">{ttft_mean:.0f}ms</div>
                        <div class="stat-label">平均 TTFT</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value">{req_throughput:.1f}</div>
                        <div class="stat-label">请求吞吐 (req/s)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value">{total_throughput:.0f}</div>
                        <div class="stat-label">总吞吐 (tok/s)</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value">{ttft_p99:.0f}ms</div>
                        <div class="stat-label">P99 TTFT</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value">{e2e_median:.0f}ms</div>
                        <div class="stat-label">中位延迟</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value">{completed}</div>
                        <div class="stat-label">成功请求</div>
                    </div>
                </div>
            </div>
"""
    
    html += """
        </div>
        
        <div class="charts">
            <div class="chart-container">
                <h3>TTFT 对比 (越低越好)</h3>
                <div class="chart-wrapper">
                    <canvas id="ttftChart"></canvas>
                </div>
            </div>
            
            <div class="chart-container">
                <h3>总吞吐量对比 (越高越好)</h3>
                <div class="chart-wrapper">
                    <canvas id="throughputChart"></canvas>
                </div>
            </div>
        </div>
        
        <div class="comparison-table">
            <h2>详细对比表</h2>
            <table>
                <thead>
                    <tr>
                        <th>策略</th>
                        <th>成功请求</th>
                        <th>Mean TTFT</th>
                        <th>Median TTFT</th>
                        <th>P99 TTFT</th>
                        <th>Mean E2E</th>
                        <th>请求吞吐</th>
                        <th>总吞吐</th>
                        <th>峰值并发</th>
                    </tr>
                </thead>
                <tbody>
"""
    
    # Add table rows
    for result in results:
        strategy_name = result.get('_filename', 'Unknown').replace('bench_', '').replace('.jsonl', '')
        completed = result.get('completed', 0)
        ttft_mean = result.get('mean_ttft_ms', 0)
        ttft_median = result.get('median_ttft_ms', 0)
        ttft_p99 = result.get('p99_ttft_ms', 0)
        e2e_mean = result.get('mean_e2e_latency_ms', 0)
        req_throughput = result.get('request_throughput', 0)
        total_throughput = result.get('total_throughput', 0)
        max_concurrent = result.get('max_concurrent_requests', 0)
        
        html += f"""
                    <tr>
                        <td><strong>{strategy_name.replace('_', ' ')}</strong></td>
                        <td>{completed}</td>
                        <td>{ttft_mean:.0f}ms</td>
                        <td>{ttft_median:.0f}ms</td>
                        <td>{ttft_p99:.0f}ms</td>
                        <td>{e2e_mean:.0f}ms</td>
                        <td>{req_throughput:.1f} req/s</td>
                        <td>{total_throughput:.0f} tok/s</td>
                        <td>{max_concurrent}</td>
                    </tr>
"""
    
    html += """
                </tbody>
            </table>
        </div>
        
        <div class="note-box">
            <h4>测试指标说明</h4>
            <p>
            <strong>TTFT (Time to First Token):</strong> 从发送请求到收到第一个 token 的时间<br>
            <strong>E2E Latency:</strong> 端到端延迟，从发送到完成所有 token 的总时间<br>
            <strong>P99:</strong> 99% 的请求都能满足的延迟指标<br>
            <strong>Throughput:</strong> 吞吐量，包括请求吞吐 (req/s) 和 token 吞吐 (tok/s)
            </p>
        </div>
        
        <div class="timestamp">
            报告生成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}<br>
            测试策略数: {len(results)}
        </div>
    </div>
    
    <script>
        const strategies = {json.dumps([r.get('_filename', '').replace('bench_', '').replace('.jsonl', '') for r in results])};
        const ttftMean = {json.dumps([r.get('mean_ttft_ms', 0) for r in results])};
        const ttftMedian = {json.dumps([r.get('median_ttft_ms', 0) for r in results])};
        const ttftP99 = {json.dumps([r.get('p99_ttft_ms', 0) for r in results])};
        const totalThroughput = {json.dumps([r.get('total_throughput', 0) for r in results])};
        const colors = ['#667eea', '#f093fb', '#4facfe', '#11998e', '#f7971e', '#fc5c7d'];
        
        // TTFT Chart
        new Chart(document.getElementById('ttftChart'), {{
            type: 'bar',
            data: {{
                labels: strategies,
                datasets: [
                    {{
                        label: 'Mean TTFT',
                        data: ttftMean,
                        backgroundColor: colors[0] + 'aa',
                        borderColor: colors[0],
                        borderWidth: 2
                    }},
                    {{
                        label: 'P99 TTFT',
                        data: ttftP99,
                        backgroundColor: colors[1] + 'aa',
                        borderColor: colors[1],
                        borderWidth: 2
                    }}
                ]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{ position: 'bottom' }},
                    tooltip: {{
                        callbacks: {{
                            label: ctx => ctx.dataset.label + ': ' + ctx.parsed.y.toFixed(0) + ' ms'
                        }}
                    }}
                }},
                scales: {{
                    y: {{
                        beginAtZero: true,
                        title: {{ display: true, text: 'Time (ms)' }}
                    }}
                }}
            }}
        }});
        
        // Throughput Chart
        new Chart(document.getElementById('throughputChart'), {{
            type: 'bar',
            data: {{
                labels: strategies,
                datasets: [{{
                    label: 'Total Throughput (tok/s)',
                    data: totalThroughput,
                    backgroundColor: colors.map(c => c + 'aa'),
                    borderColor: colors,
                    borderWidth: 2
                }}]
            }},
            options: {{
                responsive: true,
                maintainAspectRatio: false,
                plugins: {{
                    legend: {{ position: 'bottom' }},
                    tooltip: {{
                        callbacks: {{
                            label: ctx => ctx.parsed.y.toFixed(0) + ' tok/s'
                        }}
                    }}
                }},
                scales: {{
                    y: {{
                        beginAtZero: true,
                        title: {{ display: true, text: 'Tokens/sec' }}
                    }}
                }}
            }}
        }});
    </script>
</body>
</html>
"""
    
    # Write file
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)
    
    return output_path


if __name__ == "__main__":
    script_dir = Path(__file__).parent
    results_dir = str(script_dir / "benchmark-results")
    output_path = str(script_dir / "benchmark-report.html")
    
    print(f"Discovering benchmark results in: {results_dir}")
    results = discover_results(results_dir)
    
    if not results:
        print("No benchmark results found!")
        print("Please run benchmarks first:")
        print("  bash run-all-benchmarks.sh")
        sys.exit(1)
    
    print(f"Found {len(results)} benchmark result(s)")
    for r in results:
        print(f"  - {r['_filename']}")
    
    print(f"\nGenerating report...")
    output = generate_report(results, output_path)
    
    print(f"\nReport generated: {output}")
    print("Open this file in your browser to view the comprehensive report.")

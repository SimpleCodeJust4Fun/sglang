#!/usr/bin/env python3
"""
PD Request Test & Log Trace Tool

Sends requests to the Gateway and automatically correlates
with Prefill/Decode SGLang logs to show the full request flow.

Usage:
    python3 pd-test.py "Hello, how are you?"
    python3 pd-test.py --prompt "Tell me a joke" --max-tokens 100
    python3 pd-test.py --prompt "你好" --log-dir /var/log/sglang
    python3 pd-test.py --file prompts.txt
    python3 pd-test.py --concurrent 5 --prompt "Test request"
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional
from concurrent.futures import ThreadPoolExecutor, as_completed

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

# ANSI escape code regex
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\^(\[[0-9;]*[m}])')

def strip_ansi(text):
    return ANSI_RE.sub('', text)


# ============================================================
# HTTP Request Module
# ============================================================

def send_request(gateway_url, model, prompt, max_tokens, system_prompt=None):
    """Send a request to the Gateway and return response + metadata."""
    url = f"{gateway_url}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }
    if system_prompt:
        payload["messages"].insert(0, {"role": "system", "content": system_prompt})

    start_time = datetime.now()
    try:
        result = subprocess.run(
            ["curl", "-s", "-w", "\n%{http_code} %{time_total}",
             "-X", "POST", url,
             "-H", "Content-Type: application/json",
             "-d", json.dumps(payload)],
            capture_output=True, text=True, timeout=120
        )
        end_time = datetime.now()

        # Parse response
        output = result.stdout.strip()
        lines = output.split('\n')
        http_line = lines[-1]
        body = '\n'.join(lines[:-1])

        parts = http_line.split()
        status_code = int(parts[0]) if len(parts) >= 2 else 0
        duration = float(parts[1]) if len(parts) >= 2 else 0

        if status_code == 200:
            resp_json = json.loads(body)
            content = resp_json.get("choices", [{}])[0].get("message", {}).get("content", "")
            usage = resp_json.get("usage", {})
            return {
                "success": True,
                "status_code": status_code,
                "content": content,
                "prompt_tokens": usage.get("prompt_tokens", 0),
                "completion_tokens": usage.get("completion_tokens", 0),
                "duration": duration,
                "start_time": start_time,
                "end_time": end_time,
                "error": None,
            }
        else:
            return {
                "success": False,
                "status_code": status_code,
                "content": None,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "duration": duration,
                "start_time": start_time,
                "end_time": end_time,
                "error": body[:200],
            }
    except Exception as e:
        return {
            "success": False,
            "status_code": 0,
            "content": None,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "duration": (datetime.now() - start_time).total_seconds(),
            "start_time": start_time,
            "end_time": datetime.now(),
            "error": str(e),
        }


def send_request_with_request_id(gateway_url, model, prompt, max_tokens, request_id, system_prompt=None):
    """Send request with a custom request_id header for easier log correlation."""
    url = f"{gateway_url}/v1/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }
    if system_prompt:
        payload["messages"].insert(0, {"role": "system", "content": system_prompt})

    start_time = datetime.now()
    try:
        # Use -s for silent, -w for timing info, -o for body, -D for headers
        headers_file = f"/tmp/pd_test_headers_{request_id}.txt"
        body_file = f"/tmp/pd_test_body_{request_id}.txt"

        result = subprocess.run(
            ["curl", "-s", "-w", "%{http_code} %{time_total}",
             "-X", "POST", url,
             "-H", "Content-Type: application/json",
             "-H", f"X-Request-ID: {request_id}",
             "-d", json.dumps(payload),
             "-D", headers_file,
             "-o", body_file],
            capture_output=True, text=True, timeout=120
        )
        end_time = datetime.now()

        output = result.stdout.strip()

        # Parse timing and status from curl's -w output
        timing_parts = output.strip().split()
        status_code = int(timing_parts[0]) if len(timing_parts) >= 1 else 0
        duration = float(timing_parts[1]) if len(timing_parts) >= 2 else 0

        # Read headers
        gateway_request_id = request_id  # default to our sent ID
        try:
            with open(headers_file, 'r') as f:
                for header_line in f:
                    if header_line.lower().startswith('x-request-id:'):
                        gateway_request_id = header_line.split(':', 1)[1].strip()
                        break
        except Exception:
            pass

        # Read body
        body = ""
        try:
            with open(body_file, 'r') as f:
                body = f.read()
        except Exception:
            pass

        # Clean up temp files
        try:
            import os
            os.remove(headers_file)
            os.remove(body_file)
        except Exception:
            pass

        if status_code == 200:
            resp_json = json.loads(body)
            content = resp_json.get("choices", [{}])[0].get("message", {}).get("content", "")
            usage = resp_json.get("usage", {})
            actual_id = resp_json.get("id", gateway_request_id)
            return {
                "success": True,
                "status_code": status_code,
                "content": content,
                "request_id": actual_id,
                "gateway_request_id": gateway_request_id,
                "prompt_tokens": usage.get("prompt_tokens", 0),
                "completion_tokens": usage.get("completion_tokens", 0),
                "duration": duration,
                "start_time": start_time,
                "end_time": end_time,
                "error": None,
            }
        else:
            return {
                "success": False,
                "status_code": status_code,
                "content": None,
                "request_id": gateway_request_id,
                "gateway_request_id": gateway_request_id,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "duration": duration,
                "start_time": start_time,
                "end_time": end_time,
                "error": body[:200],
            }
    except Exception as e:
        return {
            "success": False,
            "status_code": 0,
            "content": None,
            "request_id": request_id,
            "gateway_request_id": request_id,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "duration": (datetime.now() - start_time).total_seconds(),
            "start_time": start_time,
            "end_time": datetime.now(),
            "error": str(e),
        }


# ============================================================
# Log Parsing Module
# ============================================================

@dataclass
class GatewayEntry:
    request_id: str
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None
    status_code: Optional[int] = None
    latency_us: Optional[int] = None
    uri: Optional[str] = None
    pd_router_events: list = field(default_factory=list)
    prefill_url: Optional[str] = None
    decode_url: Optional[str] = None
    bootstrap_room: Optional[str] = None


# ============================================================
# URL to Worker Name Mapping
# ============================================================

# Default port-to-name mapping (can be overridden by startup log parsing)
WORKER_NAME_MAP = {
    'http://127.0.0.1:30000': 'prefill-1',
    'http://127.0.0.1:30001': 'prefill-2',
    'http://127.0.0.1:30010': 'decode-1',
    'http://127.0.0.1:30011': 'decode-2',
}

def url_to_worker_name(url):
    """Convert worker URL to friendly name like 'prefill-1' or 'decode-2'."""
    if not url:
        return 'unknown'
    # Remove trailing slash if present
    url = url.rstrip('/')
    return WORKER_NAME_MAP.get(url, url)


def parse_startup_log(filepath):
    """Parse startup log to build URL-to-name mapping."""
    if not Path(filepath).exists():
        return
    
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Parse lines like:
    # Prefill-1: http://127.0.0.1:30000 (bootstrap: 9000)
    # Decode-1:  http://127.0.0.1:30010
    patterns = [
        (r'(Prefill-\d+):\s+(http://[\d.:]+)', 'prefill'),
        (r'(Decode-\d+):\s+(http://[\d.:]+)', 'decode'),
    ]
    
    for pattern, worker_type in patterns:
        for match in re.finditer(pattern, content, re.IGNORECASE):
            name = match.group(1).lower()  # e.g., 'prefill-1'
            url = match.group(2)           # e.g., 'http://127.0.0.1:30000'
            WORKER_NAME_MAP[url] = name


@dataclass
class SGLangEntry:
    rid: str
    log_file: str
    timestamp: Optional[datetime] = None
    text: Optional[str] = None
    bootstrap_host: Optional[str] = None
    bootstrap_port: Optional[str] = None
    bootstrap_room: Optional[str] = None
    finish_reason: Optional[str] = None
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    cached_tokens: Optional[int] = None
    e2e_latency: Optional[float] = None
    is_health_check: bool = False
    # Additional verbose fields
    input_text: Optional[str] = None
    output_text: Optional[str] = None
    temperature: Optional[float] = None
    max_new_tokens: Optional[int] = None
    received_time: Optional[float] = None
    # Batch info
    prefill_new_seq: Optional[int] = None
    prefill_new_token: Optional[int] = None
    prefill_cached_token: Optional[int] = None
    decode_running_req: Optional[int] = None
    decode_token: Optional[int] = None
    decode_throughput: Optional[float] = None
    # Performance metrics
    validation_time: Optional[float] = None
    received_time_perf: Optional[float] = None
    response_sent_ts: Optional[float] = None
    # Full sampling params
    sampling_params: Optional[dict] = None


def parse_timestamp(ts_str):
    try:
        return datetime.strptime(ts_str.strip(), '%Y-%m-%d %H:%M:%S')
    except Exception:
        return None


def local_to_utc(dt):
    """Convert local time to UTC."""
    if dt is None:
        return None
    try:
        import time as time_mod
        # time.timezone is offset from UTC in seconds (negative for east of UTC)
        # For UTC+8, time.timezone = -28800
        # To convert local time to UTC, we need to ADD the offset
        utc_offset_sec = time_mod.timezone if time_mod.daylight == 0 else time_mod.altzone
        utc_offset = timedelta(seconds=utc_offset_sec)
        return dt + utc_offset
    except Exception:
        return dt


def parse_gateway_log(filepath):
    entries = {}
    if not Path(filepath).exists():
        return entries

    with open(filepath, 'r') as f:
        lines = f.readlines()

    # Process line by line
    for line in lines:
        line = strip_ansi(line)

        # Extract timestamp
        ts_match = re.search(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
        if not ts_match:
            continue
        ts = parse_timestamp(ts_match.group(1))

        # Extract request_id (any format, not just chatcmpl-)
        req_match = re.search(r'request_id=["\']?([^"\'\s>]+)["\']?', line)
        if not req_match:
            continue
        req_id = req_match.group(1)

        # Skip HEALTH_CHECK requests
        if 'HEALTH_CHECK' in req_id:
            continue

        if req_id not in entries:
            entries[req_id] = GatewayEntry(request_id=req_id)

        # Check for "started processing request"
        if 'started processing request' in line:
            if not entries[req_id].start_time:
                entries[req_id].start_time = ts

            # Extract URI from the same line
            if not entries[req_id].uri:
                uri_match = re.search(r'uri=(\S+)', line)
                if uri_match:
                    entries[req_id].uri = uri_match.group(1).strip()

        # Check for "finished processing request"
        elif 'finished processing request' in line:
            if not entries[req_id].end_time:
                entries[req_id].end_time = ts

            # Extract status_code
            status_match = re.search(r'status_code=(\d+)', line)
            if status_match:
                entries[req_id].status_code = int(status_match.group(1))

            # Extract latency (try latency_us first, then latency)
            latency_match = re.search(r'latency_us=(\d+)', line)
            if not latency_match:
                latency_match = re.search(r'latency=(\d+)', line)
            if latency_match:
                entries[req_id].latency_us = int(latency_match.group(1))

        # Check for PD-ROUTER events
        if '[PD-ROUTER]' in line:
            # Extract the event message (everything after request_id)
            event_match = re.search(r'request_id=["\']?[^"\'\s>]+["\']?\s+(.*)', line)
            if event_match:
                event_text = event_match.group(1).strip()
                # Remove the module prefix if present
                if 'smg::' in event_text or 'src/' in event_text:
                    # Skip detailed processing lines, only keep high-level router events
                    pass
                else:
                    entries[req_id].pd_router_events.append({'time': ts_match.group(1), 'event': event_text})
                    
                    # Extract prefill and decode URLs
                    prefill_match = re.search(r'prefill=(http://[\d.:]+)', event_text)
                    decode_match = re.search(r'decode=(http://[\d.:]+)', event_text)
                    if prefill_match:
                        entries[req_id].prefill_url = prefill_match.group(1)
                    if decode_match:
                        entries[req_id].decode_url = decode_match.group(1)
                    
                    # Extract bootstrap_room
                    br_match = re.search(r'bootstrap_room=(\d+)', event_text)
                    if br_match:
                        entries[req_id].bootstrap_room = br_match.group(1)

    return entries


def parse_sglang_log(filepath):
    entries = {}
    if not Path(filepath).exists():
        return entries

    with open(filepath, 'r') as f:
        lines = f.readlines()

    current_rid = None
    current_entry = None
    last_timestamp = None

    for line in lines:
        line = line.strip()

        ts_match = re.search(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]', line)
        if ts_match:
            last_timestamp = local_to_utc(parse_timestamp(ts_match.group(1)))

        # Extract Prefill batch info
        if 'Prefill batch' in line and '#new-seq' in line:
            if current_entry:
                m = re.search(r'#new-seq:\s+(\d+)', line)
                if m:
                    current_entry.prefill_new_seq = int(m.group(1))
                m = re.search(r'#new-token:\s+(\d+)', line)
                if m:
                    current_entry.prefill_new_token = int(m.group(1))
                m = re.search(r'#cached-token:\s+(\d+)', line)
                if m:
                    current_entry.prefill_cached_token = int(m.group(1))

        # Extract Decode batch info
        if 'Decode batch' in line and '#running-req' in line:
            if current_entry:
                m = re.search(r'#running-req:\s+(\d+)', line)
                if m:
                    current_entry.decode_running_req = int(m.group(1))
                m = re.search(r'#token:\s+(\d+)', line)
                if m:
                    current_entry.decode_token = int(m.group(1))
                m = re.search(r'gen throughput \(token/s\):\s+([\d.]+)', line)
                if m:
                    current_entry.decode_throughput = float(m.group(1))

        if 'Receive: obj=GenerateReqInput(' in line:
            m = re.search(r"rid='([^']+)'", line)
            if not m:
                continue
            current_rid = m.group(1)

            m = re.search(r"text='([^']*)'", line)
            text = m.group(1) if m else None

            m = re.search(r"bootstrap_host='([^']*)'", line)
            bootstrap_host = m.group(1) if m else None

            m = re.search(r"bootstrap_port=([^,\s]+)", line)
            bootstrap_port = m.group(1) if m else None

            m = re.search(r"bootstrap_room=([^,\s]+)", line)
            bootstrap_room = m.group(1) if m else None

            # Extract received_time and validation_time
            m = re.search(r"validation_time=([\de.-]+)", line)
            validation_time = float(m.group(1)) if m else None

            m = re.search(r"received_time=([\de.-]+)", line)
            received_time = float(m.group(1)) if m else None

            m = re.search(r"received_time_perf=([\de.-]+)", line)
            received_time_perf = float(m.group(1)) if m else None

            # Extract full sampling_params dict
            sampling_params = None
            sp_match = re.search(r"sampling_params=(\{[^}]+\})", line)
            if sp_match:
                try:
                    # Parse the sampling params dict
                    sp_str = sp_match.group(1)
                    sampling_params = {}
                    m = re.search(r"'temperature': ([\d.]+)", sp_str)
                    if m:
                        sampling_params['temperature'] = float(m.group(1))
                    m = re.search(r"'max_new_tokens': (\d+)", sp_str)
                    if m:
                        sampling_params['max_new_tokens'] = int(m.group(1))
                    m = re.search(r"'top_p': ([\d.]+)", sp_str)
                    if m:
                        sampling_params['top_p'] = float(m.group(1))
                    m = re.search(r"'top_k': (\d+)", sp_str)
                    if m:
                        sampling_params['top_k'] = int(m.group(1))
                    m = re.search(r"'repetition_penalty': ([\d.]+)", sp_str)
                    if m:
                        sampling_params['repetition_penalty'] = float(m.group(1))
                except Exception:
                    pass

            is_health = 'HEALTH_CHECK' in current_rid

            current_entry = SGLangEntry(
                rid=current_rid,
                log_file=filepath,
                timestamp=last_timestamp,
                text=text,
                bootstrap_host=bootstrap_host,
                bootstrap_port=bootstrap_port,
                bootstrap_room=bootstrap_room,
                is_health_check=is_health,
                temperature=sampling_params.get('temperature') if sampling_params else None,
                max_new_tokens=sampling_params.get('max_new_tokens') if sampling_params else None,
                received_time=received_time,
                validation_time=validation_time,
                received_time_perf=received_time_perf,
                sampling_params=sampling_params,
            )
            entries[current_rid] = current_entry

        elif current_entry and 'Finish:' in line:
            m = re.search(r"prompt_tokens: (\d+)", line)
            if m:
                current_entry.prompt_tokens = int(m.group(1))

            m = re.search(r"completion_tokens: (\d+)", line)
            if m:
                current_entry.completion_tokens = int(m.group(1))

            m = re.search(r"cached_tokens: (\d+)", line)
            if m:
                current_entry.cached_tokens = int(m.group(1))

            m = re.search(r"e2e_latency: ([\d.]+)", line)
            if m:
                current_entry.e2e_latency = float(m.group(1))

            m = re.search(r"finish_reason:.*?type: '(\w+)'", line)
            if m:
                current_entry.finish_reason = m.group(1)

            m = re.search(r"response_sent_to_client_ts: ([\de.-]+)", line)
            if m:
                current_entry.response_sent_ts = float(m.group(1))

            # Extract output text
            m = re.search(r"'text': '([^']*)'", line)
            if m:
                current_entry.output_text = m.group(1)

            if last_timestamp and not current_entry.timestamp:
                current_entry.timestamp = last_timestamp

            current_rid = None
            current_entry = None

    return entries


def correlate_by_request_id(gw_entries, prefill_entries, decode_entries, request_id, window_sec=5, prefill_logs=None, decode_logs=None):
    """Correlate logs by request_id, gateway routing, and bootstrap_room, returning exact matches."""
    if request_id not in gw_entries:
        return None, [], []

    gw = gw_entries[request_id]
    if not gw.start_time:
        return gw, [], []

    # Gateway logs are in UTC, SGLang logs are converted to UTC in parse_sglang_log.
    # Both should now be in UTC for comparison.
    
    # Determine which log files to search based on gateway routing info
    expected_prefill_log = None
    expected_decode_log = None
    
    if gw.prefill_url:
        url = gw.prefill_url.rstrip('/')
        # Map URL to expected log file
        for log in (prefill_logs or []):
            log_path = str(log)
            # Try to match by port in URL
            if ':30000' in url and 'prefill-1' in log_path:
                expected_prefill_log = log_path
                break
            elif ':30001' in url and 'prefill-2' in log_path:
                expected_prefill_log = log_path
                break
            elif 'prefill' in log_path and len(prefill_logs or []) == 1:
                expected_prefill_log = log_path
                break
    
    if gw.decode_url:
        url = gw.decode_url.rstrip('/')
        for log in (decode_logs or []):
            log_path = str(log)
            if ':30010' in url and 'decode-1' in log_path:
                expected_decode_log = log_path
                break
            elif ':30011' in url and 'decode-2' in log_path:
                expected_decode_log = log_path
                break
            elif 'decode' in log_path and len(decode_logs or []) == 1:
                expected_decode_log = log_path
                break
    
    # Filter entries by expected log files first
    prefill_candidates = []
    decode_candidates = []
    
    for rid, pf in prefill_entries.items():
        if pf.is_health_check:
            continue
        if pf.timestamp and pf.bootstrap_room:
            # Check if this entry is from the expected log file
            if expected_prefill_log and pf.log_file != expected_prefill_log:
                continue
            diff = abs((pf.timestamp - gw.start_time).total_seconds())
            if diff <= window_sec:
                prefill_candidates.append((diff, pf))
    
    for rid, dc in decode_entries.items():
        if dc.is_health_check:
            continue
        if dc.timestamp and dc.bootstrap_room:
            # Check if this entry is from the expected log file
            if expected_decode_log and dc.log_file != expected_decode_log:
                continue
            diff = abs((dc.timestamp - gw.start_time).total_seconds())
            if diff <= window_sec:
                decode_candidates.append((diff, dc))
    
    if not prefill_candidates or not decode_candidates:
        return gw, [], []
    
    # Sort by time difference
    prefill_candidates.sort(key=lambda x: x[0])
    decode_candidates.sort(key=lambda x: x[0])
    
    # If Gateway has bootstrap_room, use it for exact matching
    matched_prefill = []
    matched_decode = []
    
    if gw.bootstrap_room:
        # Use Gateway's bootstrap_room for exact matching
        for diff, pf in prefill_candidates:
            if pf.bootstrap_room == gw.bootstrap_room:
                # Found matching prefill, now find decode with same bootstrap_room
                for diff2, dc in decode_candidates:
                    if dc.bootstrap_room == gw.bootstrap_room:
                        matched_prefill.append(pf)
                        matched_decode.append(dc)
                        break
                if matched_prefill:
                    break
    else:
        # Fallback: use prefill-decode bootstrap_room matching
        best_decode = decode_candidates[0][1]
        for diff, pf in prefill_candidates:
            if pf.bootstrap_room == best_decode.bootstrap_room:
                matched_prefill.append(pf)
                matched_decode.append(best_decode)
                break

    return gw, matched_prefill, matched_decode


def correlate_by_time(start_time, prefill_entries, decode_entries, window_sec=5):
    """Correlate logs by time window, returning only the closest matches."""
    utc_start = local_to_utc(start_time)

    matched_prefill = []
    matched_decode = []

    # Find all matches within window
    prefill_candidates = []
    decode_candidates = []
    
    for rid, pf in prefill_entries.items():
        if pf.is_health_check:
            continue
        if pf.timestamp:
            diff = abs((pf.timestamp - utc_start).total_seconds())
            if diff <= window_sec:
                prefill_candidates.append((diff, pf))

    for rid, dc in decode_entries.items():
        if dc.is_health_check:
            continue
        if dc.timestamp:
            diff = abs((dc.timestamp - utc_start).total_seconds())
            if diff <= window_sec:
                decode_candidates.append((diff, dc))
    
    # Sort by time difference and take the closest ones
    if prefill_candidates:
        prefill_candidates.sort(key=lambda x: x[0])
        # Take all entries with the same closest time (within 1 second)
        closest_time = prefill_candidates[0][0]
        matched_prefill = [pf for diff, pf in prefill_candidates if abs(diff - closest_time) <= 1.0]

    if decode_candidates:
        decode_candidates.sort(key=lambda x: x[0])
        closest_time = decode_candidates[0][0]
        matched_decode = [dc for diff, dc in decode_candidates if abs(diff - closest_time) <= 1.0]

    return matched_prefill, matched_decode


# ============================================================
# Display Module
# ============================================================

def format_time(dt):
    return dt.strftime('%H:%M:%S') if dt else 'N/A'


def format_latency_us(us):
    if us is None:
        return 'N/A'
    ms = us / 1000
    if ms < 1000:
        return f'{ms:.0f}ms'
    return f'{ms/1000:.2f}s'


def log_file_label(filepath):
    return Path(filepath).name.replace('.log', '')


def print_test_result(result):
    """Print the HTTP test result."""
    print(f"\n{C.BOLD}{C.BLUE}{'=' * 60}{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}  HTTP Test Result{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}{'=' * 60}{C.RESET}")

    if result["success"]:
        print(f"  {C.GREEN}Status:{C.RESET}     {result['status_code']} OK")
        print(f"  {C.GREEN}Duration:{C.RESET}   {result['duration']:.2f}s")
        print(f"  {C.GREEN}Tokens:{C.RESET}     prompt={result['prompt_tokens']}, completion={result['completion_tokens']}")
        if result.get('request_id'):
            gw_id = result.get('gateway_request_id', result['request_id'])
            print(f"  {C.GREEN}Req ID:{C.RESET}   {result['request_id']}")
            if gw_id != result['request_id']:
                print(f"  {C.GREEN}GW ReqID:{C.RESET} {gw_id} (from header)")
        print(f"\n  {C.BOLD}{C.CYAN}Response:{C.RESET}")
        content = result.get('content', '')
        for line in content.split('\n'):
            print(f"    {C.DIM}{line}{C.RESET}")
    else:
        print(f"  {C.RED}Status:{C.RESET}     {result['status_code']} FAILED")
        print(f"  {C.RED}Error:{C.RESET}    {result.get('error', 'Unknown error')}")
    print()


def print_gateway_section(gw_entry, verbose=False):
    """Print Gateway request details."""
    print(f"\n{C.BOLD}{C.BLUE}{'=' * 70}{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}  Gateway: {gw_entry.request_id}{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}{'=' * 70}{C.RESET}")

    print(f"  {C.CYAN}URI:{C.RESET}          {gw_entry.uri or 'N/A'}")
    print(f"  {C.CYAN}Time:{C.RESET}         {format_time(gw_entry.start_time)} → {format_time(gw_entry.end_time)}")
    print(f"  {C.CYAN}Latency:{C.RESET}      {format_latency_us(gw_entry.latency_us)}")
    print(f"  {C.CYAN}Status:{C.RESET}       {gw_entry.status_code or 'N/A'}")
    
    # Show PD routing decision prominently
    if gw_entry.prefill_url or gw_entry.decode_url:
        prefill_name = url_to_worker_name(gw_entry.prefill_url)
        decode_name = url_to_worker_name(gw_entry.decode_url)
        print(f"  {C.CYAN}Routing:{C.RESET}     {C.GREEN}Prefill={prefill_name}{C.RESET} ({gw_entry.prefill_url or 'N/A'}) → {C.RED}Decode={decode_name}{C.RESET} ({gw_entry.decode_url or 'N/A'})")

    if verbose and gw_entry.pd_router_events:
        print(f"\n  {C.BOLD}{C.MAGENTA}-- PD Router Events --{C.RESET}")
        for evt in gw_entry.pd_router_events:
            print(f"  {C.DIM}[{evt['time']}] {C.YELLOW}{evt['event']}{C.RESET}")
    print()


def print_sglang_section(entry, section_label, verbose=False, correlated_with=None):
    """Print SGLang request details."""
    # Determine icon and correlation info
    icon = "📤" if "Prefill" in section_label else "📥"
    print(f"\n  {C.BOLD}{C.GREEN}-- {icon} {section_label}: {log_file_label(entry.log_file)} --{C.RESET}")
    
    # Show correlation info if available
    if correlated_with:
        print(f"  {C.CYAN}Correlated:{C.RESET} via {correlated_with}")
    
    print(f"  {C.CYAN}Rid:{C.RESET}         {entry.rid}")
    print(f"  {C.CYAN}Time:{C.RESET}        {format_time(entry.timestamp)}")

    # Bootstrap info - highlight the mapping
    if entry.bootstrap_host or entry.bootstrap_port or entry.bootstrap_room:
        bh = entry.bootstrap_host or 'None'
        bp = entry.bootstrap_port or 'None'
        br = entry.bootstrap_room or 'None'
        print(f"  {C.CYAN}Bootstrap:{C.RESET}    host={bh}, port={bp}")
        if verbose:
            print(f"  {C.CYAN}Room ID:{C.RESET}      {br}")
            print(f"  {C.DIM}↳ This room ID maps to the corresponding Decode/Prefill worker{C.RESET}")

    # Token breakdown - show cached tokens always
    if entry.prompt_tokens is not None or entry.completion_tokens is not None:
        pt = entry.prompt_tokens or 0
        ct = entry.completion_tokens or 0
        cached = entry.cached_tokens or 0
        print(f"  {C.CYAN}Tokens:{C.RESET}       prompt={pt}, completion={ct}, cached={cached}")

    # Latency breakdown with more details
    if entry.e2e_latency is not None:
        print(f"  {C.CYAN}E2E Latency:{C.RESET}  {entry.e2e_latency:.3f}s")
        if verbose:
            # Calculate TTFT if we have response_sent_ts
            if entry.response_sent_ts and entry.received_time:
                ttft = entry.response_sent_ts - entry.received_time
                gen_time = entry.e2e_latency - ttft
                print(f"  {C.DIM}↳ TTFT: {ttft:.3f}s, Generation: {gen_time:.3f}s{C.RESET}")
            
            if entry.validation_time is not None:
                print(f"  {C.DIM}↳ Validation: {entry.validation_time*1000:.2f}ms{C.RESET}")

    if entry.finish_reason:
        print(f"  {C.CYAN}Finish:{C.RESET}       {entry.finish_reason}")

    # Verbose: show ALL the useful details from the logs
    if verbose:
        # Batch processing info
        if entry.prefill_new_seq is not None:
            print(f"\n  {C.BOLD}{C.MAGENTA}Batch Processing:{C.RESET}")
            print(f"  {C.DIM}Prefill: new_seq={entry.prefill_new_seq}, new_tok={entry.prefill_new_token}, cached={entry.prefill_cached_token}{C.RESET}")
        if entry.decode_running_req is not None:
            print(f"  {C.DIM}Decode: running={entry.decode_running_req}, tokens={entry.decode_token}, throughput={entry.decode_throughput:.2f} tok/s{C.RESET}")
        
        # Sampling parameters
        if entry.sampling_params:
            sp = entry.sampling_params
            print(f"\n  {C.BOLD}{C.MAGENTA}Sampling:{C.RESET}")
            print(f"  {C.DIM}temp={sp.get('temperature', 'N/A')}, top_p={sp.get('top_p', 'N/A')}, top_k={sp.get('top_k', 'N/A')}, max={sp.get('max_new_tokens', 'N/A')}{C.RESET}")
        
        # Performance counters
        if entry.received_time and entry.response_sent_ts:
            print(f"\n  {C.BOLD}{C.MAGENTA}Timing:{C.RESET}")
            print(f"  {C.DIM}Received: {entry.received_time:.6f} (epoch){C.RESET}")
            print(f"  {C.DIM}Response sent: {entry.response_sent_ts:.6f} (epoch){C.RESET}")
        
        # Generated text (longer preview)
        if entry.output_text:
            print(f"\n  {C.BOLD}{C.MAGENTA}Generated:{C.RESET}")
            print(f"  {C.DIM}{entry.output_text}{C.RESET}")
    elif entry.text:
        preview = entry.text[:100]
        print(f"  {C.CYAN}Text:{C.RESET}       {preview}")



def print_log_trace(gw_entry, prefill_matches, decode_matches, verbose=False, response_id=None):
    """Print the complete log trace."""
    if gw_entry:
        print_gateway_section(gw_entry, verbose)

    # Store response_id for correlation
    print_log_trace.response_id = response_id

    # Show Prefill entries with correlation info
    for pf in prefill_matches:
        # Check if this prefill has a bootstrap room that matches any decode
        correlated_info = None
        for dc in decode_matches:
            if pf.bootstrap_room and pf.bootstrap_room == dc.bootstrap_room:
                correlated_info = f"bootstrap_room={pf.bootstrap_room} → Decode rid={dc.rid[:20]}..."
                break
        print_sglang_section(pf, 'Prefill', verbose, correlated_info)

    # Show Decode entries with correlation info
    for dc in decode_matches:
        # Check correlation with prefill
        correlated_info = None
        for pf in prefill_matches:
            if dc.bootstrap_room and dc.bootstrap_room == pf.bootstrap_room:
                correlated_info = f"bootstrap_room={dc.bootstrap_room} → Prefill rid={pf.rid[:20]}..."
                break
        # Also show if response ID matches
        if not correlated_info and response_id and dc.rid == response_id:
            correlated_info = "✓ Response ID matches API response"
        print_sglang_section(dc, 'Decode', verbose, correlated_info)

    if not prefill_matches and not decode_matches:
        print(f"  {C.YELLOW}No SGLang log entries found near request time{C.RESET}")
        print(f"  {C.DIM}(Logs may be in different directory or not flushed yet){C.RESET}")

    print(f"\n{C.BLUE}{'-' * 70}{C.RESET}")


# ============================================================
# JSON Output Module
# ============================================================

def build_json_result(result, gw_match, pf_matches, dc_matches, verbose=False):
    """Build a JSON-serializable result dict."""
    entry = {
        'request_id': result.get('request_id'),
        'gateway_request_id': result.get('gateway_request_id'),
        'success': result.get('success', False),
        'status_code': result.get('status_code'),
        'duration': result.get('duration'),
        'prompt_tokens': result.get('prompt_tokens', 0),
        'completion_tokens': result.get('completion_tokens', 0),
        'content': result.get('content', ''),
        'error': result.get('error'),
    }
    
    if gw_match:
        entry['gateway'] = {
            'request_id': gw_match.request_id,
            'uri': gw_match.uri,
            'start_time': format_time(gw_match.start_time),
            'end_time': format_time(gw_match.end_time),
            'latency_us': gw_match.latency_us,
            'status_code': gw_match.status_code,
            'prefill_url': gw_match.prefill_url,
            'decode_url': gw_match.decode_url,
            'prefill_name': url_to_worker_name(gw_match.prefill_url),
            'decode_name': url_to_worker_name(gw_match.decode_url),
            'bootstrap_room': gw_match.bootstrap_room,
        }
    
    entry['prefill'] = []
    for pf in pf_matches:
        pf_entry = {
            'rid': pf.rid,
            'log_file': pf.log_file,
            'timestamp': format_time(pf.timestamp),
            'bootstrap_host': pf.bootstrap_host,
            'bootstrap_port': pf.bootstrap_port,
            'bootstrap_room': pf.bootstrap_room,
            'prompt_tokens': pf.prompt_tokens,
            'completion_tokens': pf.completion_tokens,
            'cached_tokens': pf.cached_tokens,
            'e2e_latency': pf.e2e_latency,
            'finish_reason': pf.finish_reason,
            'prefill_new_seq': pf.prefill_new_seq,
            'prefill_new_token': pf.prefill_new_token,
            'prefill_cached_token': pf.prefill_cached_token,
            'sampling_params': pf.sampling_params,
            'output_text': pf.output_text or pf.text,
        }
        entry['prefill'].append(pf_entry)
    
    entry['decode'] = []
    for dc in dc_matches:
        dc_entry = {
            'rid': dc.rid,
            'log_file': dc.log_file,
            'timestamp': format_time(dc.timestamp),
            'bootstrap_host': dc.bootstrap_host,
            'bootstrap_port': dc.bootstrap_port,
            'bootstrap_room': dc.bootstrap_room,
            'prompt_tokens': dc.prompt_tokens,
            'completion_tokens': dc.completion_tokens,
            'cached_tokens': dc.cached_tokens,
            'e2e_latency': dc.e2e_latency,
            'finish_reason': dc.finish_reason,
            'decode_running_req': dc.decode_running_req,
            'decode_token': dc.decode_token,
            'decode_throughput': dc.decode_throughput,
            'sampling_params': dc.sampling_params,
            'output_text': dc.output_text or dc.text,
        }
        entry['decode'].append(dc_entry)
    
    return entry


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser(description='PD Request Test & Log Trace Tool')
    parser.add_argument('prompt', nargs='?', default=None, help='Prompt text to send')
    parser.add_argument('--prompt', '-p', dest='prompt_opt', help='Prompt text (alternative to positional)')
    parser.add_argument('--file', '-f', help='File with prompts (one per line)')
    parser.add_argument('--gateway-url', default='http://127.0.0.1:3000', help='Gateway URL')
    parser.add_argument('--model', default='qwen2.5-0.5b-instruct', help='Model name')
    parser.add_argument('--max-tokens', type=int, default=50, help='Max tokens to generate')
    parser.add_argument('--system', '-s', help='System prompt')
    parser.add_argument('--concurrent', '-c', type=int, default=1, help='Number of concurrent requests')
    parser.add_argument('--log-dir', default='/tmp', help='Log directory')
    parser.add_argument('--gateway-log', help='Gateway log file')
    parser.add_argument('--prefill-log', help='Prefill log file')
    parser.add_argument('--decode-log', help='Decode log file')
    parser.add_argument('--window', type=int, default=60, help='Time correlation window (seconds)')
    parser.add_argument('--no-trace', action='store_true', help='Skip log tracing')
    parser.add_argument('--no-response', action='store_true', help='Skip showing response content')
    parser.add_argument('--tail', type=int, default=0, help='Show last N lines of each log after request (for debugging)')
    parser.add_argument('--verbose', '-v', action='store_true', help='Show detailed information including bootstrap room mapping, timing breakdown, and full request/response text')
    parser.add_argument('--json', '-j', action='store_true', help='Output results in JSON format (for programmatic use)')
    args = parser.parse_args()

    # Get prompt
    prompt = args.prompt or args.prompt_opt
    if not prompt and not args.file:
        if args.json:
            # In JSON mode, output empty array instead of help
            print(json.dumps([]))
        else:
            parser.print_help()
        return

    # Resolve log paths - auto-discover log files
    log_dir = Path(args.log_dir)

    # Gateway log discovery
    if args.gateway_log:
        gateway_log = args.gateway_log
    else:
        # Try common Gateway log patterns
        gateway_candidates = [
            log_dir / 'sgl-gateway-test.log',
            log_dir / 'sgl-gateway.log',
        ]
        # Also check for policy-specific logs
        for pattern in log_dir.glob('sgl-gateway-*.log'):
            gateway_candidates.append(pattern)
        # Also check for gateway.log
        if (log_dir / 'gateway.log').exists():
            gateway_candidates.append(log_dir / 'gateway.log')

        # Find the most recently modified non-empty gateway log
        gateway_log = None
        for candidate in gateway_candidates:
            if candidate.exists() and candidate.stat().st_size > 0:
                if gateway_log is None or candidate.stat().st_mtime > Path(gateway_log).stat().st_mtime:
                    gateway_log = str(candidate)

        if not gateway_log:
            print(f"{C.YELLOW}Warning: No Gateway log found in {log_dir}{C.RESET}")
            print(f"{C.DIM}  Searched: sgl-gateway-test.log, sgl-gateway-*.log, gateway.log{C.RESET}")
            gateway_log = str(log_dir / 'sgl-gateway-test.log')  # fallback

    # Prefill log discovery
    prefill_logs = []
    if args.prefill_log:
        prefill_logs.append(args.prefill_log)
    else:
        for pattern in [log_dir / 'sglang-prefill-*.log', log_dir / 'sglang-prefill.log']:
            if '*' in str(pattern):
                prefill_logs.extend(sorted([str(p) for p in log_dir.glob(pattern.name)]))
            elif pattern.exists():
                prefill_logs.append(str(pattern))

    # Decode log discovery
    decode_logs = []
    if args.decode_log:
        decode_logs.append(args.decode_log)
    else:
        for pattern in [log_dir / 'sglang-decode-*.log', log_dir / 'sglang-decode.log']:
            if '*' in str(pattern):
                decode_logs.extend(sorted([str(p) for p in log_dir.glob(pattern.name)]))
            elif pattern.exists():
                decode_logs.append(str(pattern))

    # Collect prompts
    prompts = []
    if args.file:
        with open(args.file, 'r') as f:
            prompts = [line.strip() for line in f if line.strip()]
    elif prompt:
        prompts = [prompt] * args.concurrent

    if not prompts:
        if args.json:
            print(json.dumps([]))
        else:
            print(f"{C.RED}No prompts to process{C.RESET}")
        return

    # Parse startup log to build URL-to-name mapping
    startup_log = '/tmp/pd-startup.log'
    parse_startup_log(startup_log)

    # In JSON mode, suppress normal output
    if not args.json:
        print(f"{C.BOLD}{C.CYAN}PD Test & Log Trace Tool{C.RESET}")
        print(f"{C.DIM}Gateway: {args.gateway_url} | Model: {args.model}{C.RESET}")

        # Show log file details
        gw_path = Path(gateway_log)
        gw_size = gw_path.stat().st_size if gw_path.exists() else 0
        gw_status = f"{gw_size/1024:.1f}KB" if gw_size > 0 else f"{C.RED}NOT FOUND{C.RESET}"
        print(f"{C.DIM}Gateway log: {gateway_log} ({gw_status}){C.RESET}")

        for p in prefill_logs:
            p_path = Path(p)
            p_size = p_path.stat().st_size if p_path.exists() else 0
            p_status = f"{p_size/1024:.1f}KB" if p_size > 0 else f"{C.RED}EMPTY{C.RESET}"
            print(f"{C.DIM}Prefill log: {p} ({p_status}){C.RESET}")

        for d in decode_logs:
            d_path = Path(d)
            d_size = d_path.stat().st_size if d_path.exists() else 0
            d_status = f"{d_size/1024:.1f}KB" if d_size > 0 else f"{C.RED}EMPTY{C.RESET}"
            print(f"{C.DIM}Decode log:  {d} ({d_status}){C.RESET}")
        print()

    # Initialize JSON results collection
    json_results = []

    # Process each prompt
    for i, p in enumerate(prompts):
        request_id = f"test-{int(time.time())}-{i}"
        
        # Only print progress in non-JSON mode
        if not args.json:
            print(f"{C.BOLD}{C.YELLOW}[{i+1}/{len(prompts)}] Sending request: {p[:50]}{'...' if len(p) > 50 else ''}{C.RESET}")

        # Send request
        result = send_request_with_request_id(
            args.gateway_url, args.model, p, args.max_tokens,
            request_id, args.system
        )

        # Display HTTP result
        if not args.json:
            if not args.no_response:
                print_test_result(result)
            else:
                status = f"{C.GREEN}OK{C.RESET}" if result["success"] else f"{C.RED}FAIL{C.RESET}"
                print(f"  {C.CYAN}Status:{C.RESET} {status}, {C.CYAN}Duration:{C.RESET} {result['duration']:.2f}s")

        # Trace logs
        gw_match = None
        pf_matches = []
        dc_matches = []
        
        if not args.no_trace:
            # Re-parse logs for each request (to get latest)
            gw_entries = parse_gateway_log(gateway_log)

            pf_entries = {}
            for log in prefill_logs:
                pf_entries.update(parse_sglang_log(log))

            dc_entries = {}
            for log in decode_logs:
                dc_entries.update(parse_sglang_log(log))

            # Try to correlate by gateway request_id (from response header)
            gw_req_id = result.get('gateway_request_id', result.get('request_id', request_id))
            gw_match, pf_matches, dc_matches = correlate_by_request_id(
                gw_entries, pf_entries, dc_entries, gw_req_id, args.window,
                prefill_logs=prefill_logs, decode_logs=decode_logs
            )

            # Fall back to response body request_id
            if not gw_match or (not pf_matches and not dc_matches):
                body_req_id = result.get('request_id', request_id)
                if body_req_id != gw_req_id:
                    gw_match, pf_matches, dc_matches = correlate_by_request_id(
                        gw_entries, pf_entries, dc_entries, body_req_id, args.window,
                        prefill_logs=prefill_logs, decode_logs=decode_logs
                    )

            # Fall back to time-based correlation
            if not gw_match or (not pf_matches and not dc_matches):
                pf_matches, dc_matches = correlate_by_time(
                    result['start_time'], pf_entries, dc_entries, args.window
                )
                # Find the gateway entry by time
                for gwid, gw in gw_entries.items():
                    if gw.start_time and abs((gw.start_time - local_to_utc(result['start_time'])).total_seconds()) <= args.window:
                        gw_match = gw
                        break

            if not args.json:
                if gw_match:
                    print_log_trace(gw_match, pf_matches, dc_matches, 
                                   verbose=args.verbose, 
                                   response_id=result.get('request_id'))
                else:
                    print(f"\n  {C.YELLOW}No Gateway log entry found for this request{C.RESET}")
                    # Show diagnostic info
                    if gw_entries:
                        print(f"  {C.DIM}(Found {len(gw_entries)} gateway entries, but none matched by time window){C.RESET}")
                        print(f"  {C.DIM}Gateway entries found: {list(gw_entries.keys())[:5]}{'...' if len(gw_entries) > 5 else ''}{C.RESET}")
                    else:
                        print(f"  {C.DIM}(Gateway log parsed but contains 0 request entries){C.RESET}")
                        if Path(gateway_log).exists():
                            print(f"  {C.DIM}Last 5 lines of {gateway_log}:{C.RESET}")
                            try:
                                with open(gateway_log, 'r') as f:
                                    lines = f.readlines()
                                    for line in lines[-5:]:
                                        print(f"    {C.DIM}{line.rstrip()}{C.RESET}")
                            except Exception:
                                pass
                        else:
                            print(f"  {C.DIM}Gateway log file does not exist: {gateway_log}{C.RESET}")
                    print(f"  {C.DIM}Prefill entries: {len(pf_entries)}, Decode entries: {len(dc_entries)}{C.RESET}")
                    print()
        else:
            # In --no-trace mode, still try to get gateway routing info from logs
            gw_entries = parse_gateway_log(gateway_log)
            gw_req_id = result.get('gateway_request_id', result.get('request_id', request_id))
            
            # Try to find gateway entry by request_id
            if gw_req_id in gw_entries:
                gw_match = gw_entries[gw_req_id]
            else:
                # Fall back to time-based correlation
                for gwid, gw in gw_entries.items():
                    if gw.start_time and abs((gw.start_time - local_to_utc(result['start_time'])).total_seconds()) <= args.window:
                        gw_match = gw
                        break

        # Store JSON result if in JSON mode
        if args.json:
            json_results.append(build_json_result(result, gw_match, pf_matches, dc_matches, args.verbose))
        else:
            # Show raw log tail if requested (only in non-JSON mode)
            if args.tail > 0:
                print(f"\n{C.DIM}-- Raw Log Tail (last {args.tail} lines) --{C.RESET}")
                for label, log_path in [('Gateway', gateway_log)] + \
                                       [(f'Prefill-{j}', lp) for j, lp in enumerate(prefill_logs, 1)] + \
                                       [(f'Decode-{j}', lp) for j, lp in enumerate(decode_logs, 1)]:
                    if Path(log_path).exists():
                        print(f"\n{C.BOLD}{C.CYAN}[{label}]{C.RESET}")
                        try:
                            with open(log_path, 'r') as f:
                                lines = f.readlines()
                                for line in lines[-args.tail:]:
                                    print(f"  {C.DIM}{line.rstrip()}{C.RESET}")
                        except Exception as e:
                            print(f"  {C.RED}Error reading: {e}{C.RESET}")
                print()

            if i < len(prompts) - 1:
                print()

    # Output JSON results
    if args.json:
        print(json.dumps(json_results, indent=2))
    else:
        print(f"\n{C.GREEN}Test complete. Processed {len(prompts)} request(s).{C.RESET}")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
PD Disaggregation Request Tracer

Correlates Gateway policy selection -> Prefill processing -> Decode processing
across the full PD disaggregation request flow.

Usage:
    python3 trace-pd-requests.py [--request-id REQ_ID] [--last N] [--all]
    python3 trace-pd-requests.py --help

Examples:
    # Show last 3 requests (default)
    python3 trace-pd-requests.py

    # Trace a specific request
    python3 trace-pd-requests.py --request-id chatcmpl-sj8uwHRMqotqBBJ9FbR2VXnA

    # Show all requests
    python3 trace-pd-requests.py --all

    # Trace by bootstrap room ID
    python3 trace-pd-requests.py --bootstrap-room 1234567890

    # Use custom log directory
    python3 trace-pd-requests.py --log-dir /var/log/sglang
"""

import argparse
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

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

# ANSI escape code regex pattern
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\^(\[[0-9;]*[m}])')


def strip_ansi(text):
    """Remove ANSI escape codes from text."""
    return ANSI_RE.sub('', text)


@dataclass
class GatewayEntry:
    request_id: str
    start_time: Optional[datetime] = None
    end_time: Optional[datetime] = None
    status_code: Optional[int] = None
    latency_us: Optional[int] = None
    uri: Optional[str] = None
    pd_router_events: list = field(default_factory=list)


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
    e2e_latency: Optional[float] = None
    is_health_check: bool = False


def parse_timestamp(ts_str):
    """Parse timestamp from log format like 2026-04-23 00:31:34"""
    try:
        return datetime.strptime(ts_str.strip(), '%Y-%m-%d %H:%M:%S')
    except Exception:
        return None


def local_to_utc(dt):
    """Convert a naive local datetime to naive UTC datetime."""
    if dt is None:
        return None
    utc_offset_sec = time.timezone if time.daylight == 0 else time.altzone
    utc_offset = timedelta(seconds=-utc_offset_sec)
    return dt - utc_offset


def parse_gateway_log(filepath):
    """Parse Gateway log entries for request start/finish events."""
    entries = {}
    if not Path(filepath).exists():
        return entries

    with open(filepath, 'r') as f:
        content = strip_ansi(f.read())

    # Request start: 2026-04-22 16:39:24 INFO http_request{method=POST uri=/v1/chat/completions ... request_id="chatcmpl-xxx"}: started processing
    for m in re.finditer(
        r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*request_id="(chatcmpl-[^"]+)".*started processing',
        content
    ):
        ts = parse_timestamp(m.group(1))
        req_id = m.group(2)
        if req_id not in entries:
            entries[req_id] = GatewayEntry(request_id=req_id)
        entries[req_id].start_time = ts

    # Request finish: 2026-04-22 16:39:24 INFO http_request{... request_id="chatcmpl-xxx" status_code=200 latency=487950}: finished processing
    for m in re.finditer(
        r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*request_id="(chatcmpl-[^"]+)".*status_code=(\d+).*latency=(\d+)',
        content
    ):
        ts = parse_timestamp(m.group(1))
        req_id = m.group(2)
        status = int(m.group(3))
        latency = int(m.group(4))
        if req_id not in entries:
            entries[req_id] = GatewayEntry(request_id=req_id)
        entries[req_id].end_time = ts
        entries[req_id].status_code = status
        entries[req_id].latency_us = latency

    # URI (from start event line)
    for m in re.finditer(
        r'uri=(/\S+).*request_id="(chatcmpl-[^"]+)"',
        content
    ):
        uri = m.group(1)
        req_id = m.group(2)
        if req_id in entries:
            entries[req_id].uri = uri

    # PD Router debug events (only appear at debug level)
    for m in re.finditer(
        r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[PD-ROUTER\].*request_id=(chatcmpl-[^ ]+)\s+(.*)',
        content
    ):
        ts = m.group(1)
        req_id = m.group(2)
        event = m.group(3).strip()
        if req_id not in entries:
            entries[req_id] = GatewayEntry(request_id=req_id)
        entries[req_id].pd_router_events.append({'time': ts, 'event': event})

    return entries


def parse_sglang_log(filepath):
    """Parse SGLang log for GenerateReqInput/Finish pairs."""
    entries = {}
    if not Path(filepath).exists():
        return entries

    with open(filepath, 'r') as f:
        lines = f.readlines()

    current_rid = None
    current_entry = None
    last_timestamp = None  # Track last seen timestamp for lines without one
    line_idx = 0

    for line in lines:
        raw_line = line
        line = line.strip()

        # Always try to extract timestamp from every line (for tracking)
        ts_match = re.search(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]', line)
        if ts_match:
            last_timestamp = local_to_utc(parse_timestamp(ts_match.group(1)))

        # Detect Receive: obj=GenerateReqInput(...)
        if 'Receive: obj=GenerateReqInput(' in line:
            # Extract rid
            m = re.search(r"rid='([^']+)'", line)
            if not m:
                continue
            current_rid = m.group(1)

            # Use last_timestamp from previous lines (Receive line has no timestamp)
            timestamp = last_timestamp

            # Extract text
            m = re.search(r"text='([^']*)'", line)
            text = m.group(1) if m else None

            # Extract bootstrap info
            m = re.search(r"bootstrap_host='([^']*)'", line)
            bootstrap_host = m.group(1) if m else None

            m = re.search(r"bootstrap_port=([^,\s]+)", line)
            bootstrap_port = m.group(1) if m else None

            m = re.search(r"bootstrap_room=([^,\s]+)", line)
            bootstrap_room = m.group(1) if m else None

            is_health = 'HEALTH_CHECK' in current_rid

            current_entry = SGLangEntry(
                rid=current_rid,
                log_file=filepath,
                timestamp=timestamp,
                text=text,
                bootstrap_host=bootstrap_host,
                bootstrap_port=bootstrap_port,
                bootstrap_room=bootstrap_room,
                is_health_check=is_health,
            )
            entries[current_rid] = current_entry

        # Detect Finish: obj=GenerateReqInput(...)... out={...}
        elif current_entry and 'Finish:' in line:
            m = re.search(r"prompt_tokens: (\d+)", line)
            if m:
                current_entry.prompt_tokens = int(m.group(1))

            m = re.search(r"completion_tokens: (\d+)", line)
            if m:
                current_entry.completion_tokens = int(m.group(1))

            m = re.search(r"e2e_latency: ([\d.]+)", line)
            if m:
                current_entry.e2e_latency = float(m.group(1))

            m = re.search(r"finish_reason:.*?type: '(\w+)'", line)
            if m:
                current_entry.finish_reason = m.group(1)

            # Use the last tracked timestamp as finish time
            if last_timestamp and not current_entry.timestamp:
                current_entry.timestamp = last_timestamp

            current_rid = None
            current_entry = None

        line_idx += 1

    return entries


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
    name = Path(filepath).name
    return name.replace('.log', '')


def print_gateway_section(entry):
    """Print Gateway request details."""
    print(f"\n{C.BOLD}{C.BLUE}{'=' * 60}{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}  Gateway: {entry.request_id}{C.RESET}")
    print(f"{C.BOLD}{C.BLUE}{'=' * 60}{C.RESET}")

    print(f"  {C.CYAN}URI:{C.RESET}        {entry.uri or 'N/A'}")
    print(f"  {C.CYAN}Start Time:{C.RESET} {format_time(entry.start_time)}")
    print(f"  {C.CYAN}End Time:{C.RESET}   {format_time(entry.end_time)}")
    print(f"  {C.CYAN}Latency:{C.RESET}    {format_latency_us(entry.latency_us)}")
    print(f"  {C.CYAN}Status:{C.RESET}     {entry.status_code or 'N/A'}")

    if entry.pd_router_events:
        print(f"\n  {C.BOLD}{C.MAGENTA}-- PD Router Events --{C.RESET}")
        for evt in entry.pd_router_events:
            print(f"  {C.DIM}[{evt['time']}] {C.YELLOW}{evt['event']}{C.RESET}")
    print()


def print_sglang_section(entry, section_label):
    """Print SGLang request details (skip health checks)."""
    if entry.is_health_check:
        return

    print(f"  {C.BOLD}{C.GREEN}-- {section_label} --{C.RESET}")
    print(f"  {C.CYAN}Node:{C.RESET}     {log_file_label(entry.log_file)}")
    print(f"  {C.CYAN}Rid:{C.RESET}       {entry.rid}")
    print(f"  {C.CYAN}Time:{C.RESET}      {format_time(entry.timestamp)}")

    if entry.bootstrap_host or entry.bootstrap_port or entry.bootstrap_room:
        bh = entry.bootstrap_host or 'None'
        bp = entry.bootstrap_port or 'None'
        br = entry.bootstrap_room or 'None'
        print(f"  {C.CYAN}Bootstrap:{C.RESET} host={bh}, port={bp}, room={br}")

    if entry.prompt_tokens is not None or entry.completion_tokens is not None:
        pt = entry.prompt_tokens or 0
        ct = entry.completion_tokens or 0
        print(f"  {C.CYAN}Tokens:{C.RESET}    prompt={pt}, completion={ct}")

    if entry.e2e_latency is not None:
        print(f"  {C.CYAN}E2E Latency:{C.RESET} {entry.e2e_latency:.3f}s")

    if entry.finish_reason:
        print(f"  {C.CYAN}Finish:{C.RESET}    {entry.finish_reason}")

    if entry.text:
        preview = entry.text[:100]
        print(f"  {C.CYAN}Text:{C.RESET}      {preview}")

    print()


def correlate_by_time(gw_entry, prefill_entries, decode_entries, window_sec=3):
    """Find prefill and decode entries within time window of gateway request."""
    if not gw_entry.start_time:
        return [], []

    matched_prefill = []
    for rid, pf in prefill_entries.items():
        if pf.is_health_check:
            continue
        if pf.timestamp and abs((pf.timestamp - gw_entry.start_time).total_seconds()) <= window_sec:
            matched_prefill.append(pf)

    matched_decode = []
    for rid, dc in decode_entries.items():
        if dc.is_health_check:
            continue
        if dc.timestamp and abs((dc.timestamp - gw_entry.start_time).total_seconds()) <= window_sec:
            matched_decode.append(dc)

    return matched_prefill, matched_decode


def main():
    parser = argparse.ArgumentParser(description='PD Disaggregation Request Tracer')
    parser.add_argument('--request-id', help='Trace a specific Gateway request_id')
    parser.add_argument('--last', type=int, default=3, help='Show last N requests (default: 3)')
    parser.add_argument('--all', action='store_true', help='Trace all requests')
    parser.add_argument('--bootstrap-room', help='Trace by bootstrap room ID')
    parser.add_argument('--log-dir', default='/tmp', help='Log directory (default: /tmp)')
    parser.add_argument('--gateway-log', help='Gateway log file')
    parser.add_argument('--prefill-log', help='Prefill log file (prefill-1)')
    parser.add_argument('--decode-log', help='Decode log file (decode-1)')
    parser.add_argument('--window', type=int, default=3, help='Time correlation window in seconds')
    args = parser.parse_args()

    # Resolve log file paths
    log_dir = Path(args.log_dir)
    gateway_log = args.gateway_log or str(log_dir / 'sgl-gateway-test.log')
    prefill_1_log = args.prefill_log or str(log_dir / 'sglang-prefill-1.log')
    prefill_2_log = args.prefill_log.replace('prefill-1', 'prefill-2') if args.prefill_log else str(log_dir / 'sglang-prefill-2.log')
    decode_1_log = args.decode_log or str(log_dir / 'sglang-decode-1.log')
    decode_2_log = args.decode_log.replace('decode-1', 'decode-2') if args.decode_log else str(log_dir / 'sglang-decode-2.log')

    # Warn about missing logs
    for log in [gateway_log, prefill_1_log, prefill_2_log, decode_1_log, decode_2_log]:
        if not Path(log).exists():
            print(f"{C.YELLOW}Warning: {log} not found{C.RESET}", file=sys.stderr)

    # Parse all logs
    print(f"{C.DIM}Parsing logs...{C.RESET}")
    gateway_entries = parse_gateway_log(gateway_log)

    prefill_entries = {}
    for log in [prefill_1_log, prefill_2_log]:
        prefill_entries.update(parse_sglang_log(log))

    decode_entries = {}
    for log in [decode_1_log, decode_2_log]:
        decode_entries.update(parse_sglang_log(log))

    print(f"{C.DIM}Found {len(gateway_entries)} gateway requests, "
          f"{len(prefill_entries)} prefill entries, {len(decode_entries)} decode entries{C.RESET}\n")

    # Determine which requests to display
    if args.request_id:
        req_ids = [args.request_id] if args.request_id in gateway_entries else []
    elif args.bootstrap_room:
        req_ids = []
        for rid, entry in prefill_entries.items():
            if entry.bootstrap_room == args.bootstrap_room:
                for gw_id, gw in gateway_entries.items():
                    if gw.start_time and entry.timestamp and \
                       abs((entry.timestamp - gw.start_time).total_seconds()) <= args.window:
                        req_ids.append(gw_id)
                        break
        req_ids = list(set(req_ids))
    elif args.all:
        req_ids = list(gateway_entries.keys())
    else:
        req_ids = list(gateway_entries.keys())[-args.last:]

    if not req_ids:
        print(f"{C.YELLOW}No matching requests found.{C.RESET}")
        return

    # Display each correlated request
    for req_id in req_ids:
        gw = gateway_entries[req_id]
        print_gateway_section(gw)

        prefill_matches, decode_matches = correlate_by_time(
            gw, prefill_entries, decode_entries, args.window
        )

        for pf in prefill_matches:
            print_sglang_section(pf, 'Prefill')

        for dc in decode_matches:
            print_sglang_section(dc, 'Decode')

        if not prefill_matches and not decode_matches:
            print(f"  {C.YELLOW}No SGLang entries found within {args.window}s time window{C.RESET}\n")

        print(f"{C.BLUE}{'-' * 60}{C.RESET}")

    print(f"\n{C.GREEN}Trace complete.{C.RESET}")


if __name__ == '__main__':
    main()

#!/bin/bash
# PD End-to-End Test Tool
# Sends requests to Gateway and retrieves corresponding logs from all components
# Works without Python - pure bash implementation

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Defaults
GATEWAY_URL="http://127.0.0.1:3000"
MODEL="qwen2.5-0.5b-instruct"
MAX_TOKENS=50
PROMPT=""
LOG_DIR="/tmp"
GATEWAY_LOG=""
CONCURRENCY=1
TAIL_LINES=0
SHOW_TRACE=true
SHOW_RESPONSE=true

# Known log file patterns (absolute paths)
KNOWN_GATEWAY_LOGS=(
    "/tmp/sgl-gateway-request_classification.log"
    "/tmp/sgl-gateway-round_robin.log"
    "/tmp/sgl-gateway-cache_aware.log"
    "/tmp/sgl-gateway-test.log"
)
KNOWN_PREFILL_LOGS=(
    "/tmp/sglang-prefill-1.log"
    "/tmp/sglang-prefill-2.log"
    "/tmp/sglang-prefill.log"
)
KNOWN_DECODE_LOGS=(
    "/tmp/sglang-decode-1.log"
    "/tmp/sglang-decode-2.log"
    "/tmp/sglang-decode.log"
)

# Print usage
usage() {
    echo -e "${BOLD}${CYAN}PD End-to-End Test Tool${RESET}"
    echo ""
    echo "Usage:"
    echo "  $0 \"prompt text\" [options]"
    echo ""
    echo "Options:"
    echo "  -g, --gateway URL     Gateway URL (default: ${GATEWAY_URL})"
    echo "  -m, --model NAME      Model name (default: ${MODEL})"
    echo "  -t, --tokens N        Max tokens (default: ${MAX_TOKENS})"
    echo "  -c, --concurrent N    Concurrent requests (default: ${CONCURRENCY})"
    echo "  -l, --log-dir DIR     Log directory (default: ${LOG_DIR})"
    echo "  --gateway-log FILE    Gateway log file (auto-detect if not set)"
    echo "  --tail N              Show last N lines of logs after test"
    echo "  --no-trace            Skip log retrieval"
    echo "  --no-response         Hide response content"
    echo "  -h, --help            Show this help"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--gateway) GATEWAY_URL="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
        -c|--concurrent) CONCURRENCY="$2"; shift 2 ;;
        -l|--log-dir) LOG_DIR="$2"; shift 2 ;;
        --gateway-log) GATEWAY_LOG="$2"; shift 2 ;;
        --tail) TAIL_LINES="$2"; shift 2 ;;
        --no-trace) SHOW_TRACE=false; shift ;;
        --no-response) SHOW_RESPONSE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo -e "${RED}Unknown option: $1${RESET}"; usage; exit 1 ;;
        *) PROMPT="$1"; shift ;;
    esac
done

if [ -z "$PROMPT" ]; then
    usage
    exit 1
fi

echo -e "${BOLD}${CYAN}PD End-to-End Test Tool${RESET}"
echo -e "${DIM}Gateway: ${GATEWAY_URL} | Model: ${MODEL} | Max Tokens: ${MAX_TOKENS}${RESET}"
echo -e "${DIM}Log Directory: ${LOG_DIR}${RESET}"
echo ""

# Check Gateway
echo -n "Checking Gateway... "
if curl -sf --max-time 3 "${GATEWAY_URL}/health" >/dev/null 2>&1; then
    echo -e "${GREEN}OK${RESET}"
else
    echo -e "${RED}NOT RESPONDING${RESET}"
    echo -e "${YELLOW}Warning: Gateway may not be running at ${GATEWAY_URL}${RESET}"
fi
echo ""

# Auto-detect Gateway log if not specified
if [ -z "$GATEWAY_LOG" ]; then
    # First try known absolute paths
    for candidate in "${KNOWN_GATEWAY_LOGS[@]}"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            GATEWAY_LOG="$candidate"
            break
        fi
    done
    # Fallback to glob pattern
    if [ -z "$GATEWAY_LOG" ]; then
        GATEWAY_LOG=$(ls -t /tmp/sgl-gateway-*.log 2>/dev/null | head -1)
    fi
    # Final fallback to log_dir
    if [ -z "$GATEWAY_LOG" ]; then
        for candidate in \
            "${LOG_DIR}/sgl-gateway-test.log" \
            "${LOG_DIR}/sgl-gateway.log"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                GATEWAY_LOG="$candidate"
                break
            fi
        done
    fi
fi

# Function to send a single request and retrieve logs
send_request_and_get_logs() {
    local prompt="$1"
    local req_num="${2:-1}"
    local request_id="pd-test-${req_num}-$(date +%s)"

    echo -e "${BOLD}${YELLOW}[Request ${req_num}]${RESET} ${PROMPT:0:80}"
    echo -e "${DIM}Request ID: ${request_id}${RESET}"

    # Create temp files
    local resp_file=$(mktemp)
    local headers_file=$(mktemp)
    trap "rm -f ${resp_file} ${headers_file}" RETURN

    # Record start time
    local start_time=$(date -u +"%Y-%m-%d %H:%M:%S")
    local start_epoch=$(date +%s)

    # Send request
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -X POST "${GATEWAY_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Request-ID: ${request_id}" \
        -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":${MAX_TOKENS}}" \
        --dump-header "${headers_file}" \
        -o "${resp_file}" \
        --max-time 120 2>/dev/null) || http_code="000"

    local end_time=$(date -u +"%Y-%m-%d %H:%M:%S")

    # Parse response
    echo ""
    echo -e "${BOLD}${BLUE}=== HTTP Response ===${RESET}"

    if [ "$http_code" = "200" ]; then
        echo -e "  ${GREEN}Status:${RESET} ${http_code} OK"

        # Extract fields using grep/sed (basic JSON parsing)
        local resp_id prompt_tokens completion_tokens content
        resp_id=$(grep -o '"id":"[^"]*"' "${resp_file}" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "unknown")
        prompt_tokens=$(grep -o '"prompt_tokens":[0-9]*' "${resp_file}" 2>/dev/null | head -1 | cut -d: -f2 || echo "0")
        completion_tokens=$(grep -o '"completion_tokens":[0-9]*' "${resp_file}" 2>/dev/null | head -1 | cut -d: -f2 || echo "0")

        echo -e "  ${GREEN}Response ID:${RESET} ${resp_id}"
        echo -e "  ${GREEN}Tokens:${RESET} prompt=${prompt_tokens:-0}, completion=${completion_tokens:-0}"

        if [ "$SHOW_RESPONSE" = true ]; then
            echo ""
            echo -e "  ${BOLD}${CYAN}Response Content:${RESET}"
            content=$(grep -o '"content":"[^"]*"' "${resp_file}" 2>/dev/null | head -1 | cut -d'"' -f4 | sed 's/\\n/\n/g; s/\\\"/"/g' || echo "")
            if [ -n "$content" ]; then
                echo -e "    ${DIM}${content}${RESET}"
            else
                echo -e "    ${DIM}(empty or truncated)${RESET}"
            fi
        fi
    else
        echo -e "  ${RED}Status:${RESET} ${http_code} FAILED"
        local error_body
        error_body=$(head -c 200 "${resp_file}" 2>/dev/null || echo "")
        if [ -n "$error_body" ]; then
            echo -e "  ${RED}Error:${RESET} ${error_body}"
        fi
        resp_id="failed-${req_num}"
    fi

    echo ""

    # Retrieve logs
    if [ "$SHOW_TRACE" = true ]; then
        echo -e "${BOLD}${BLUE}=== Log Retrieval ===${RESET}"

        # 1. Gateway logs
        if [ -n "$GATEWAY_LOG" ] && [ -f "$GATEWAY_LOG" ]; then
            echo -e "\n${BOLD}${CYAN}[Gateway]${RESET} ${GATEWAY_LOG}"

            # Search by response ID (from API) - this is the actual Gateway request_id
            local gw_lines
            gw_lines=$(grep "${resp_id}" "${GATEWAY_LOG}" 2>/dev/null | grep -E "(started|finished) processing request" || true)

            # Also search by our custom request_id if X-Request-ID header was used
            if [ -z "$gw_lines" ]; then
                gw_lines=$(grep "${request_id}" "${GATEWAY_LOG}" 2>/dev/null | grep -E "(started|finished) processing request" || true)
            fi

            # If not found, search by time window
            if [ -z "$gw_lines" ]; then
                local search_time
                search_time=$(date -u -d "@${start_epoch}" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u +"%Y-%m-%d %H:%M:%S")
                local time_prefix="${search_time%:[0-9][0-9]}"

                gw_lines=$(grep "${time_prefix}" "${GATEWAY_LOG}" 2>/dev/null | grep -E "(started|finished) processing request" | head -5 || true)
            fi

            if [ -n "$gw_lines" ] && [ -n "$(echo "$gw_lines" | tr -d '[:space:]')" ]; then
                echo -e "  ${GREEN}Found entries:${RESET}"
                echo "$gw_lines" | while IFS= read -r line; do
                    [ -n "$line" ] && echo -e "  ${DIM}${line}${RESET}"
                done
            else
                echo -e "  ${YELLOW}No matching entries found${RESET}"
                echo -e "  ${DIM}(Searched by request_id=${request_id}, response_id=${resp_id})${RESET}"

                # Show last few lines for debugging
                echo -e "  ${DIM}Last 3 lines of Gateway log:${RESET}"
                tail -3 "${GATEWAY_LOG}" 2>/dev/null | while IFS= read -r line; do
                    echo -e "  ${DIM}  ${line}${RESET}"
                done
            fi
        else
            echo -e "\n${BOLD}${CYAN}[Gateway]${RESET} ${YELLOW}No log file found${RESET}"
            echo -e "  ${DIM}Searched: ${LOG_DIR}/sgl-gateway*.log${RESET}"
        fi

        # 2. Prefill logs - use known absolute paths
        local prefill_logs=()
        for pf in "${KNOWN_PREFILL_LOGS[@]}"; do
            if [ -f "$pf" ] && [ -s "$pf" ]; then
                prefill_logs+=("$pf")
            fi
        done
        # Also check glob patterns
        for pf in /tmp/sglang-prefill-*.log; do
            [ -f "$pf" ] && [[ ! " ${prefill_logs[*]} " =~ " ${pf} " ]] && prefill_logs+=("$pf")
        done

        if [ ${#prefill_logs[@]} -gt 0 ]; then
            for pf_log in "${prefill_logs[@]}"; do
                echo -e "\n${BOLD}${CYAN}[Prefill]${RESET} $(basename "$pf_log")"

                # SGLang logs have timestamps on separate lines from Receive/Finish.
                # Search for the most recent non-HEALTH_CHECK entries.
                local pf_lines
                pf_lines=$(grep -v HEALTH_CHECK "$pf_log" 2>/dev/null | grep -E "(Receive:|Finish:)" | tail -10 || true)

                if [ -n "$pf_lines" ] && [ -n "$(echo "$pf_lines" | tr -d '[:space:]')" ]; then
                    echo -e "  ${GREEN}Recent entries:${RESET}"
                    echo "$pf_lines" | while IFS= read -r line; do
                        [ -n "$line" ] && echo -e "  ${DIM}${line}${RESET}"
                    done
                else
                    echo -e "  ${DIM}No non-health-check entries found${RESET}"
                fi
            done
        else
            echo -e "\n${BOLD}${CYAN}[Prefill]${RESET} ${DIM}No log files found${RESET}"
        fi

        # 3. Decode logs - use known absolute paths
        local decode_logs=()
        for dc in "${KNOWN_DECODE_LOGS[@]}"; do
            if [ -f "$dc" ] && [ -s "$dc" ]; then
                decode_logs+=("$dc")
            fi
        done
        # Also check glob patterns
        for dc in /tmp/sglang-decode-*.log; do
            [ -f "$dc" ] && [[ ! " ${decode_logs[*]} " =~ " ${dc} " ]] && decode_logs+=("$dc")
        done
        if [ ${#decode_logs[@]} -gt 0 ]; then
            for dc_log in "${decode_logs[@]}"; do
                echo -e "\n${BOLD}${CYAN}[Decode]${RESET} $(basename "$dc_log")"

                # SGLang logs have timestamps on separate lines from Receive/Finish.
                # Search for the most recent non-HEALTH_CHECK entries.
                local dc_lines
                dc_lines=$(grep -v HEALTH_CHECK "$dc_log" 2>/dev/null | grep -E "(Receive:|Finish:)" | tail -10 || true)

                if [ -n "$dc_lines" ] && [ -n "$(echo "$dc_lines" | tr -d '[:space:]')" ]; then
                    echo -e "  ${GREEN}Recent entries:${RESET}"
                    echo "$dc_lines" | while IFS= read -r line; do
                        [ -n "$line" ] && echo -e "  ${DIM}${line}${RESET}"
                    done
                else
                    echo -e "  ${DIM}No non-health-check entries found${RESET}"
                fi
            done
        else
            echo -e "\n${BOLD}${CYAN}[Decode]${RESET} ${DIM}No log files found${RESET}"
        fi
    fi

    echo -e "\n${BLUE}$(printf '%.0s-' {1..60})${RESET}"
}

# Main execution
for i in $(seq 1 $CONCURRENCY); do
    if [ $CONCURRENCY -gt 1 ]; then
        prompt="${PROMPT} [${i}/${CONCURRENCY}]"
    else
        prompt="${PROMPT}"
    fi

    send_request_and_get_logs "$prompt" "$i"

    if [ $i -lt $CONCURRENCY ]; then
        echo ""
    fi
done

# Show tail logs if requested
if [ "$TAIL_LINES" -gt 0 ]; then
    echo -e "\n${BOLD}${DIM}=== Raw Log Tail (last ${TAIL_LINES} lines) ===${RESET}"

    # Gateway log tail
    if [ -n "$GATEWAY_LOG" ] && [ -f "$GATEWAY_LOG" ]; then
        echo -e "\n${BOLD}${CYAN}[Gateway Tail]${RESET}"
        tail -n "$TAIL_LINES" "$GATEWAY_LOG" 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done
    fi

    # Prefill logs tail
    for pf_log in "${KNOWN_PREFILL_LOGS[@]}" /tmp/sglang-prefill-*.log; do
        [ -f "$pf_log" ] || continue
        echo -e "\n${BOLD}${CYAN}[Prefill Tail: $(basename "$pf_log")]${RESET}"
        tail -n "$TAIL_LINES" "$pf_log" 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done
    done

    # Decode logs tail
    for dc_log in "${KNOWN_DECODE_LOGS[@]}" /tmp/sglang-decode-*.log; do
        [ -f "$dc_log" ] || continue
        echo -e "\n${BOLD}${CYAN}[Decode Tail: $(basename "$dc_log")]${RESET}"
        tail -n "$TAIL_LINES" "$dc_log" 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done
    done
fi

echo -e "\n${GREEN}Test complete.${RESET}"

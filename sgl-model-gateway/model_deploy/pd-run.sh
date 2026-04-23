#!/bin/bash
# PD Request Test & Log Trace Tool
#
# Sends a request to the Gateway and immediately tails the SGLang logs
# to show the Prefill and Decode processing.
#
# Usage:
#   ./pd-run.sh "Hello"                     # Simple request
#   ./pd-run.sh -c 3 "Test"                 # 3 concurrent requests
#   ./pd-run.sh -t 100 "Long prompt"        # Max 100 tokens
#   ./pd-run.sh -m qwen2.5-1.5b-instruct "Prompt"
#   ./pd-run.sh --no-log "Just test"        # Skip log tailing

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
GATEWAY_URL="http://127.0.0.1:3000"
MODEL="qwen2.5-0.5b-instruct"
MAX_TOKENS=50
CONCURRENT=1
LOG_DIR="/tmp"
SYSTEM_PROMPT=""
SKIP_LOGS=false

# Parse arguments
PROMPT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--concurrent) CONCURRENT="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -t|--tokens) MAX_TOKENS="$2"; shift 2 ;;
        -g|--gateway) GATEWAY_URL="$2"; shift 2 ;;
        -l|--log-dir) LOG_DIR="$2"; shift 2 ;;
        -s|--system) SYSTEM_PROMPT="$2"; shift 2 ;;
        --no-log) SKIP_LOGS=true; shift ;;
        -h|--help)
            echo -e "${CYAN}PD Request Test & Log Trace Tool${NC}"
            echo ""
            echo "Usage:"
            echo "  $0 [options] \"prompt text\""
            echo ""
            echo "Options:"
            echo "  -c, --concurrent N    Concurrent requests (default: 1)"
            echo "  -m, --model NAME      Model name"
            echo "  -t, --tokens N        Max tokens (default: 50)"
            echo "  -g, --gateway URL     Gateway URL"
            echo "  -l, --log-dir DIR     Log directory (default: /tmp)"
            echo "  -s, --system TEXT     System prompt"
            echo "  --no-log              Skip log tailing"
            echo "  -h, --help            This help"
            exit 0
            ;;
        *) PROMPT="$1"; shift ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo -e "${RED}Error: No prompt provided${NC}"
    echo "Usage: $0 \"prompt text\""
    exit 1
fi

# Check Gateway
if ! curl -sf --max-time 2 "$GATEWAY_URL/health" >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Gateway not responding at $GATEWAY_URL${NC}"
fi

# Get timestamp before request
BEFORE_TS=$(date '+%Y-%m-%d %H:%M:%S')
BEFORE_EPOCH=$(date +%s)

echo -e "${BOLD}${CYAN}PD Test & Log Trace${NC}"
echo -e "${DIM}Gateway: $GATEWAY_URL | Model: $MODEL | Tokens: $MAX_TOKENS${NC}"
echo ""

# Send request(s)
if [ "$CONCURRENT" -eq 1 ]; then
    echo -e "${YELLOW}[Sending request]${NC} $PROMPT"

    # Build curl command
    CURL_CMD="curl -s -X POST $GATEWAY_URL/v1/chat/completions"
    CURL_CMD="$CURL_CMD -H 'Content-Type: application/json'"

    if [ -n "$SYSTEM_PROMPT" ]; then
        PAYLOAD="{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"system\", \"content\": \"$SYSTEM_PROMPT\"}, {\"role\": \"user\", \"content\": \"$PROMPT\"}], \"max_tokens\": $MAX_TOKENS}"
    else
        PAYLOAD="{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}], \"max_tokens\": $MAX_TOKENS}"
    fi

    CURL_CMD="$CURL_CMD -d '$PAYLOAD'"

    # Execute and capture output
    RESPONSE=$($CURL_CMD)

    # Parse response
    STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','ERROR')[:100])" 2>/dev/null || echo "PARSE_ERROR")
    TOKENS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('usage',{}); print(f\"prompt={u.get('prompt_tokens',0)}, completion={u.get('completion_tokens',0)}\")" 2>/dev/null || echo "N/A")
    REQ_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','N/A'))" 2>/dev/null || echo "N/A")

    echo ""
    echo -e "${BOLD}${BLUE}=== HTTP Response ===${NC}"
    echo -e "  ${GREEN}Req ID:${NC} $REQ_ID"
    echo -e "  ${GREEN}Tokens:${NC} $TOKENS"
    echo -e "  ${GREEN}Response:${NC} $STATUS"
else
    echo -e "${YELLOW}[Sending $CONCURRENT concurrent requests]${NC} $PROMPT"

    for i in $(seq 1 $CONCURRENT); do
        if [ -n "$SYSTEM_PROMPT" ]; then
            PAYLOAD="{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"system\", \"content\": \"$SYSTEM_PROMPT\"}, {\"role\": \"user\", \"content\": \"$PROMPT $i\"}], \"max_tokens\": $MAX_TOKENS}"
        else
            PAYLOAD="{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT $i\"}], \"max_tokens\": $MAX_TOKENS}"
        fi

        curl -s -X POST "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" > "/tmp/pd-test-resp-$i.json" &
    done
    wait

    for i in $(seq 1 $CONCURRENT); do
        REQ_ID=$(python3 -c "import json; d=json.load(open('/tmp/pd-test-resp-$i.json')); print(d.get('id','N/A'))" 2>/dev/null || echo "N/A")
        TOKENS=$(python3 -c "import json; d=json.load(open('/tmp/pd-test-resp-$i.json')); u=d.get('usage',{}); print(f\"prompt={u.get('prompt_tokens',0)}, completion={u.get('completion_tokens',0)}\")" 2>/dev/null || echo "N/A")
        echo -e "  ${GREEN}Req $i:${NC} $REQ_ID | $TOKENS"
        rm -f "/tmp/pd-test-resp-$i.json"
    done
fi

# Wait a moment for logs to flush
sleep 1

if [ "$SKIP_LOGS" = false ]; then
    echo ""
    echo -e "${BOLD}${BLUE}=== SGLang Logs (since $BEFORE_TS) ===${NC}"

    AFTER_EPOCH=$(date +%s)

    # Function to tail a log file
    tail_log() {
        local log_file=$1
        local label=$2

        if [ ! -f "$log_file" ]; then
            return
        fi

        # Find lines after our request timestamp
        local found=false
        local in_section=false

        while IFS= read -r line; do
            # Check if line has a timestamp
            if [[ "$line" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\] ]]; then
                local line_ts="${BASH_REMATCH[1]}"

                # Compare timestamps (string comparison works for this format)
                if [[ "$line_ts" > "$BEFORE_TS" || "$line_ts" == "$BEFORE_TS" ]]; then
                    in_section=true
                fi
            fi

            if [ "$in_section" = true ]; then
                # Show relevant lines (Receive, Finish, bootstrap, etc)
                if [[ "$line" == *"Receive:"* ]] || [[ "$line" == *"Finish:"* ]] || \
                   [[ "$line" == *"bootstrap"* ]] || [[ "$line" == *"GenerateReqInput"* ]] || \
                   [[ "$line" == *"HEALTH_CHECK"* ]] || [[ "$line" == *"chunk"* ]]; then
                    if [ "$found" = false ]; then
                        echo -e "\n${MAGENTA}[$label]${NC}"
                        found=true
                    fi
                    echo -e "  ${DIM}${line}${NC}"
                fi
            fi
        done < "$log_file"
    }

    # Tail all logs
    for f in "$LOG_DIR"/sglang-prefill-*.log; do
        [ -f "$f" ] && tail_log "$f" "Prefill: $(basename $f)"
    done

    for f in "$LOG_DIR"/sglang-decode-*.log; do
        [ -f "$f" ] && tail_log "$f" "Decode: $(basename $f)"
    done

    # Also check Gateway log if it exists
    for f in "$LOG_DIR"/sgl-gateway-*.log "$LOG_DIR"/gateway.log; do
        if [ -f "$f" ]; then
            echo -e "\n${MAGENTA}[Gateway: $(basename $f)]${NC}"
            tail -20 "$f" | while IFS= read -r line; do
                echo -e "  ${DIM}${line}${NC}"
            done
            break
        fi
    done
fi

echo ""
echo -e "${GREEN}Test complete.${NC}"

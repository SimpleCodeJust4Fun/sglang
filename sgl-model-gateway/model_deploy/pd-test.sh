#!/bin/bash
# Quick PD Test Wrapper - Convenience wrapper for pd-test.py
#
# Usage:
#   ./pd-test.sh                        # Interactive prompt
#   ./pd-test.sh "Hello"                # Quick single test
#   ./pd-test.sh -c 3 "Test request"    # 3 concurrent requests
#   ./pd-test.sh --batch prompts.txt    # Batch from file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/pd-test.py"

# Default settings
GATEWAY_URL="http://127.0.0.1:3000"
MODEL="qwen2.5-0.5b-instruct"
LOG_DIR="/tmp"
MAX_TOKENS=50

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if Gateway is running
check_gateway() {
    if ! curl -sf --max-time 2 "$GATEWAY_URL/health" >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: Gateway not responding at $GATEWAY_URL${NC}"
        echo -e "Start it with: bash $SCRIPT_DIR/start-gateway-multi.sh round_robin"
        echo ""
    fi
}

# Show help
show_help() {
    echo -e "${CYAN}PD Test Tool - Quick Test & Log Trace${NC}"
    echo ""
    echo "Usage:"
    echo "  $0 [options] \"prompt text\""
    echo "  $0 --batch prompts.txt"
    echo ""
    echo "Options:"
    echo "  -c, --concurrent N    Send N concurrent requests (default: 1)"
    echo "  -m, --model NAME      Model name (default: $MODEL)"
    echo "  -t, --tokens N        Max tokens (default: $MAX_TOKENS)"
    echo "  -g, --gateway URL     Gateway URL (default: $GATEWAY_URL)"
    echo "  -l, --log-dir DIR     Log directory (default: $LOG_DIR)"
    echo "  -s, --system TEXT     System prompt"
    echo "  --no-trace            Skip log tracing"
    echo "  --no-response         Hide response content"
    echo "  --batch FILE          Batch test from file (one prompt per line)"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 \"Hello, how are you?\""
    echo "  $0 -c 5 \"Load test\""
    echo "  $0 --batch prompts.txt"
    echo "  $0 -m qwen2.5-1.5b-instruct -t 200 \"Long response\""
    echo "  $0 --no-response -c 10 \"Benchmark\""
}

# Parse arguments
CONCURRENCY=1
BATCH_FILE=""
SYSTEM_PROMPT=""
NO_TRACE=""
NO_RESPONSE=""
PROMPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--concurrent)
            CONCURRENCY="$2"
            shift 2
            ;;
        -m|--model)
            MODEL="$2"
            shift 2
            ;;
        -t|--tokens)
            MAX_TOKENS="$2"
            shift 2
            ;;
        -g|--gateway)
            GATEWAY_URL="$2"
            shift 2
            ;;
        -l|--log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        -s|--system)
            SYSTEM_PROMPT="$2"
            shift 2
            ;;
        --batch)
            BATCH_FILE="$2"
            shift 2
            ;;
        --no-trace)
            NO_TRACE="--no-trace"
            shift
            ;;
        --no-response)
            NO_RESPONSE="--no-response"
            shift
            ;;
        --tail)
            TAIL_ARG="--tail $2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            PROMPT="$1"
            shift
            ;;
    esac
done

# Check gateway
check_gateway

# Build command - try python first, fallback to python3
if command -v python &> /dev/null; then
    PYTHON_CMD="python"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
else
    echo -e "${YELLOW}Error: No Python found${NC}"
    echo "Please install Python or use: python model_deploy/pd-test.py"
    exit 1
fi

CMD="$PYTHON_CMD \"$PYTHON_SCRIPT\" --gateway-url $GATEWAY_URL --model $MODEL --max-tokens $MAX_TOKENS --log-dir $LOG_DIR --concurrent $CONCURRENCY"

if [ -n "$SYSTEM_PROMPT" ]; then
    CMD="$CMD --system \"$SYSTEM_PROMPT\""
fi

if [ -n "$NO_TRACE" ]; then
    CMD="$CMD $NO_TRACE"
fi

if [ -n "$NO_RESPONSE" ]; then
    CMD="$CMD $NO_RESPONSE"
fi

if [ -n "$TAIL_ARG" ]; then
    CMD="$CMD $TAIL_ARG"
fi

if [ -n "$BATCH_FILE" ]; then
    CMD="$CMD --file \"$BATCH_FILE\""
elif [ -n "$PROMPT" ]; then
    CMD="$CMD \"$PROMPT\""
else
    # Interactive mode
    echo -e "${CYAN}Enter prompt (empty to quit):${NC}"
    read -r PROMPT
    if [ -z "$PROMPT" ]; then
        exit 0
    fi
    CMD="$CMD \"$PROMPT\""
fi

# Execute
echo -e "${GREEN}Running: $CMD${NC}"
echo ""
eval "$CMD"

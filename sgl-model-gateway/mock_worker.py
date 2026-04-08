from fastapi import FastAPI, Request
import uvicorn
import json
import sys

app = FastAPI()
worker_name = sys.argv[2] if len(sys.argv) > 2 else "worker"

@app.get("/health")
async def health():
    return {"status": "healthy"}

@app.get("/health_generate")
async def health_generate():
    return {"status": "healthy"}

@app.get("/get_model_info")
async def model_info():
    return {"model_path": "mock-model", "is_generation": True}

@app.get("/v1/models")
async def models():
    return {"data": [{"id": "mock-model", "object": "model"}]}

@app.post("/generate")
async def generate(request: Request):
    body = await request.json()
    print(f"\n[{worker_name}] Received request:")
    print(json.dumps(body, indent=2))

    # 检查是否包含 bootstrap 信息（PD 模式的标志）
    if "bootstrap_host" in body:
        print(f"[{worker_name}] Bootstrap info detected:")
        print(f"  host: {body.get('bootstrap_host')}")
        print(f"  port: {body.get('bootstrap_port')}")
        print(f"  room: {body.get('bootstrap_room')}")

    return {"text": f"Response from {worker_name}", "meta_info": {"id": "test-123"}}

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    print(f"\n[{worker_name}] Chat request:")
    print(json.dumps(body, indent=2))
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": f"Hello from {worker_name}"},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    }

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8100
    print(f"Starting {worker_name} on port {port}")
    uvicorn.run(app, host="127.0.0.1", port=port)
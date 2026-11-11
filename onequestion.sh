#!/usr/bin/env bash
# ./onequestion.sh <port> : ask the GPTQ-failure question 3x with thinking off and on
: "${VLLM_API_KEY:=$(cat ~/.config/vllm/api-key)}"; export VLLM_API_KEY
P=${1:-8000}
for think in false true; do for i in 1 2 3; do
curl -s localhost:$P/v1/chat/completions -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' -d "{\"model\":\"qwen3.8-27b\",\"temperature\":0,\"max_tokens\":4000,\"chat_template_kwargs\":{\"enable_thinking\":$think},\"messages\":[{\"role\":\"user\",\"content\":\"What does this Python expression evaluate to? sum(i*i for i in range(4))\nReply with only the value, no quotes, no explanation.\"}]}" | python3 -c "import json,sys; m=json.load(sys.stdin)['choices'][0]['message']; print('thinking=$think', repr((m.get('content') or '').strip()))"
done; done

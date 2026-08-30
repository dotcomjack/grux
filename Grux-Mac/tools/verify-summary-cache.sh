#!/bin/bash
# verify-summary-cache.sh
#
# Live verification that ChatService.composeSystemBlocks's THREAD_SUMMARY
# cache breakpoint actually hits Anthropic's prompt cache. Sends three
# real /v1/messages calls and reads the usage.cache_creation_input_tokens
# / cache_read_input_tokens fields from the response:
#
#   Call 1: First-ever request, expect cache WRITE (cache_creation > 0).
#   Call 2: Same stable+summary, different volatile, expect FULL CACHE
#           READ for the stable+summary prefix (cache_read > 0).
#   Call 3: Same stable, NEW summary text (simulates compaction firing
#           between turns), expect PARTIAL cache read via Anthropic's
#           automatic lookback (cache_read > 0, but smaller than Call 2).
#
# Pass criteria: cache_read_input_tokens > 0 on both Call 2 and Call 3.
# Failing Call 3 means lookback isn't recovering the stable-only prefix,
# the stable block is probably under the model's minimum cacheable size
# (4096 tokens for Haiku 4.5, 1024 for Sonnet 4.5).
#
# Requires: ANTHROPIC_API_KEY env var, jq, curl.

set -euo pipefail

KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$KEY" ]; then
    echo "ERROR: ANTHROPIC_API_KEY not set" >&2
    exit 1
fi
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }

MODEL="${MODEL:-claude-haiku-4-5-20251001}"

# A stable block deliberately sized to clear Haiku 4.5's 4096-token minimum
# cacheable prefix. ~400 unique-ish lines × ~80 chars ≈ 32 KB ≈ 8000 tokens.
# Includes a UUID-shaped tag per run so we don't share cache entries with
# other Grux-shaped prompts already in Anthropic's cache.
RUN_TAG="grux-cache-smoke-$(date +%s)-$$"
build_stable() {
    echo "GRUX SMOKE TEST run=$RUN_TAG"
    echo "This is a stable persona/tools block sized to clear the Haiku 4.5 prompt-cache minimum (4096 tokens)."
    for i in $(seq 1 400); do
        echo "Stable persona line $i for run $RUN_TAG: assistants persona, voice rules, brand canon, tool catalog, trust boundaries, music strategy, screen reading rules, agent swarm doctrine."
    done
}
STABLE="$(build_stable)"

# A representative rolling THREAD_SUMMARY (~400 tokens worth of folded
# decisions + open questions, mirroring what ChatCompactor.summarize emits).
build_summary() {
    local label="$1"
    echo "THREAD_SUMMARY ($label):"
    for i in $(seq 1 30); do
        echo "- Decision $i ($label): ship the rolling-summarization gap, the THREAD_SUMMARY cache block, and the assistant-controlled compact_thread_now / recall_thread_summary tools. Open: instrumentation in a follow-up branch."
    done
}
SUMMARY_A="$(build_summary 'pre-compaction')"
SUMMARY_B="$(build_summary 'POST-compaction-FRESH')"

# Volatile block, must NEVER be cached, so always include a unique stamp.
mk_volatile() {
    echo "NOW: $(date -u +%FT%T.%NZ), pid=$$ tag=$RUN_TAG vol=$RANDOM"
}

# Build the system array as Anthropic JSON.
mk_payload() {
    local stable="$1"
    local summary="$2"
    local volatile="$3"
    jq -n \
        --arg model "$MODEL" \
        --arg stable "$stable" \
        --arg summary "$summary" \
        --arg volatile "$volatile" \
        '{
            model: $model,
            max_tokens: 16,
            system: [
                {type: "text", text: $stable, cache_control: {type: "ephemeral"}},
                {type: "text", text: $summary, cache_control: {type: "ephemeral"}},
                {type: "text", text: $volatile}
            ],
            messages: [
                {role: "user", content: "Reply with one word: ok"}
            ]
        }'
}

call_anthropic() {
    local label="$1"
    local payload="$2"
    local resp
    resp=$(curl -sS https://api.anthropic.com/v1/messages \
        -H "x-api-key: $KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload")
    if echo "$resp" | jq -e '.error' > /dev/null 2>&1; then
        echo "FAIL [$label]: $(echo "$resp" | jq -c '.error')" >&2
        exit 2
    fi
    echo "$resp"
}

format_usage() {
    local label="$1"
    local resp="$2"
    echo "[$label] $(echo "$resp" | jq -c '{cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, input: .usage.input_tokens, output: .usage.output_tokens, model: .model}')"
}

echo "=== verify-summary-cache.sh, model=$MODEL run=$RUN_TAG ==="
echo

# Call 1: cold cache, expect WRITE.
PAYLOAD1=$(mk_payload "$STABLE" "$SUMMARY_A" "$(mk_volatile)")
RESP1=$(call_anthropic "1" "$PAYLOAD1")
format_usage "Call 1 (cold, expect cache_creation > 0)" "$RESP1"

# Anthropic's cache write isn't synchronously visible to the next request,
# there's a brief (≤ a few seconds) propagation window. Sleep so Call 2's
# read sees the write deterministically. Production traffic is naturally
# spaced (humans take >2s between turns) so this isn't a real-world concern.
sleep 2

# Call 2: same stable+summary, different volatile, expect FULL READ.
PAYLOAD2=$(mk_payload "$STABLE" "$SUMMARY_A" "$(mk_volatile)")
RESP2=$(call_anthropic "2" "$PAYLOAD2")
format_usage "Call 2 (same prefix, expect cache_read close to Call 1 cache_creation)" "$RESP2"

sleep 2

# Call 3: stable unchanged, summary CHANGED, exercises lookback to find
# the stable-only cache entry from Call 1's chain.
PAYLOAD3=$(mk_payload "$STABLE" "$SUMMARY_B" "$(mk_volatile)")
RESP3=$(call_anthropic "3" "$PAYLOAD3")
format_usage "Call 3 (summary changed, expect cache_read > 0 from stable-only lookback)" "$RESP3"

CR2=$(echo "$RESP2" | jq -r '.usage.cache_read_input_tokens // 0')
CR3=$(echo "$RESP3" | jq -r '.usage.cache_read_input_tokens // 0')
CC1=$(echo "$RESP1" | jq -r '.usage.cache_creation_input_tokens // 0')

echo
echo "=== Verdict ==="
echo "Call 1 cache_creation_input_tokens : $CC1"
echo "Call 2 cache_read_input_tokens     : $CR2  (full prefix)"
echo "Call 3 cache_read_input_tokens     : $CR3  (stable-only via lookback)"
echo

if [ "$CR2" -gt 0 ] && [ "$CR3" -gt 0 ]; then
    echo "PASS: cache hits confirmed on both subsequent calls."
    echo "      Live savings on the cached portion ≈ ${CR2} input tokens × (1 - 0.10) per turn at 5-min window."
    exit 0
else
    echo "FAIL: cache did not behave as expected."
    [ "$CR2" -eq 0 ] && echo "  - Call 2 missed the cache. Likely the prefix didn't match (stable+summary changed unexpectedly) or didn't clear the model's minimum size."
    [ "$CR3" -eq 0 ] && echo "  - Call 3 missed the cache via lookback. Likely the stable block alone is under the minimum cacheable size for this model."
    exit 1
fi

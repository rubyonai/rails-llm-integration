# Concerns & Technical Debt

## Tech Debt

| Area | Issue | Severity | Location |
|------|-------|----------|----------|
| Generator templates | Templates reference patterns not fully implemented in templates themselves | Medium | `templates/` |
| Retryable concern | Uses `sleep()` in synchronous context for retry backoff | Medium | `references/service-patterns.md` |
| Config reloading | Non-thread-safe config reload mechanism | Medium | `references/proxy-routing.md` |
| Token estimation | Character-based token counting (rough approximation, not tokenizer-accurate) | Low | `references/proxy-routing.md` |

## Known Issues

| Issue | Impact | Location |
|-------|--------|----------|
| Streaming response token usage not recorded | Cost tracking inaccurate for streaming | `references/client-setup.md` |
| Prompt SHA calculation may fail on binary content | Traceability gaps | `references/prompt-management.md` |
| Proxy client error handling gaps | Inconsistent error types across providers | `references/client-setup.md` |
| Missing API key validation at boot | Runtime failures instead of startup errors | `references/generators.md` |
| Cost tracker Redis expiration | Budget state can silently reset | `references/proxy-routing.md` |

## Security Concerns

| Concern | Risk | Mitigation |
|---------|------|------------|
| API key leakage in logs | API keys could appear in debug output | VCR filter_sensitive_data, log scrubbing recommended |
| Eval cases storing PII | Eval datasets may contain user data | Documented but no automatic redaction |
| Config file allows hardcoded keys | `llm.yml` could contain raw API keys | Recommended to use Rails credentials or ENV vars |
| Prompt injection | User input in prompts could manipulate LLM | Input sanitization recommended but not enforced |

## Performance Concerns

| Area | Issue | Impact |
|------|-------|--------|
| Prompt rendering | Synchronous ERB rendering in request path | Adds latency to every LLM call |
| Redis operations | Unbatched Redis calls for cost tracking | Multiple round-trips per request |
| VCR cassettes | Cassette files grow unbounded | CI slowdown over time |
| HTTP connection pooling | No explicit connection pooling documented | New TCP connection per request possible |

## Fragile Areas

| Area | Why Fragile | Risk |
|------|-------------|------|
| Exception handling | Broad `rescue StandardError` in some patterns | Swallows unexpected errors |
| PromptRenderer | Dynamic method definition for helpers | Hard to debug, surprising behavior |
| Router fallback | Silent fallback on routing errors | Requests route to wrong provider silently |
| Job class constantization | `String#constantize` for job class lookup | Unsafe if input not validated |

## Scaling Limits

| Component | Limit | When Hit |
|-----------|-------|----------|
| Redis cost tracking | Single Redis instance assumed | High-throughput multi-region |
| Batch jobs | No checkpointing for large batches | Batch restart loses progress |
| VCR cassettes | Unbounded file growth | Large test suites |
| Eval scoring | Sequential scoring pipeline | Large eval datasets |

## Dependency Risks

| Dependency | Risk | Notes |
|------------|------|-------|
| ruby-openai | Version pinning needed | Breaking changes between major versions |
| anthropic-rb | Pre-1.0 status | API may change before stable release |
| Redis | Hard dependency for cost tracking | No fallback if Redis unavailable |
| Braintrust | Eval pipeline dependency | External service availability |

## Missing Features

- Request deduplication (identical prompts within time window)
- Graceful degradation when LLM providers are down
- Cost alerting (budget threshold notifications)
- A/B testing framework for prompt variants
- Automatic prompt versioning and rollback

## Test Coverage Gaps

- Config reload race conditions under concurrency
- Missing prompt file error paths
- Streaming cost tracking accuracy
- Batch job cancellation mid-flight
- Concurrent budget check atomicity
- Fallback chain exhaustion behavior

# Testing Patterns

## Framework & Strategy

The skill defines a 3-tier testing pyramid for LLM-integrated Rails apps:

```
    /  Eval Regression  \       ← Nightly CI, real API calls
   /  Integration (VCR)  \      ← Record once, replay in CI
  /   Unit Tests (Stubs)   \    ← Every CI run, fast, deterministic
```

All testing patterns are documented in `references/testing-guide.md`.

## Test Layers

### Level 1: Unit Tests (WebMock Stubs)

- **Tool**: WebMock via `spec/support/llm_stubs.rb`
- **Helpers**: `stub_llm_response`, `stub_llm_rate_limit`, `stub_llm_timeout`, `stub_llm_content_filter`
- **Purpose**: Test service logic without API calls
- **Speed**: Fast, deterministic, no API keys needed
- **Pattern**: Stub HTTP layer, test Result object success/failure/metadata

### Level 2: Integration Tests (VCR)

- **Tool**: VCR with WebMock hook
- **Cassette dir**: `spec/cassettes/llm/`
- **Request matching**: method + URI + body (ignores headers)
- **Sensitive data**: Filtered via `filter_sensitive_data` for API keys
- **Re-record**: Delete cassette, run with real API keys

### Level 3: Shared Examples

- **Location**: `spec/support/shared_examples/llm_service.rb`
- **Contract**: Every LLM service must return `LLM::Result`, handle rate limits, handle timeouts, include `trace_id` and `model` in metadata
- **Usage**: `it_behaves_like "an LLM service", described_class`

### Level 4: Prompt Rendering Tests

- **Purpose**: Test ERB template rendering independently from API calls
- **Tool**: `LLM::PromptRenderer.render_text` and `.render`
- **Tests**: Variable interpolation, optional section omission, system prompt content

### Level 5: Quality Threshold Tests

- **Purpose**: Validate output parsing against saved fixtures
- **Fixture format**: YAML in `spec/fixtures/llm/`
- **Assertions**: Presence, length, absence of AI disclosure phrases

## Response Fixture Factory

`spec/factories/llm_responses.rb` provides factory methods:
- `LLMResponseFactory.product_description(title:, description:)`
- `LLMResponseFactory.classification(category:)`
- `LLMResponseFactory.json_response(data)`
- `LLMResponseFactory.error_response(status:, message:, type:)`

All return normalized response shape: `{choices: [{message: {role:, content:}}], usage: {input_tokens:, output_tokens:}, model:}`

## CI Strategy

| Job | Trigger | API Keys | What Runs |
|-----|---------|----------|-----------|
| `unit-tests` | push, PR | None | All specs except `spec/eval/` |
| `eval-regression` | Nightly schedule | OPENAI, ANTHROPIC, BRAINTRUST | `spec/eval/` with `--tag eval` |

## Key Rules

1. Unit tests use WebMock stubs — fast, deterministic, no API keys
2. Integration tests use VCR — record once, replay forever
3. Shared examples enforce consistency across all services
4. Test prompt rendering separately from API calls
5. Quality fixtures catch parsing regressions
6. Real API calls only in nightly CI — never block PRs on LLM latency
7. Filter API keys in VCR cassettes — never commit secrets

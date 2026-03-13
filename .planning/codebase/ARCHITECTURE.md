# Architecture

**Analysis Date:** 2026-03-13

## Pattern Overview

**Overall:** Service-centric LLM integration with Rails conventions.

The Rails LLM Integration skill teaches production-grade LLM patterns by treating AI calls as first-class Rails citizens — similar to ActionMailer for email, ActiveJob for background work, and database.yml for config. Every LLM call flows through three core layers: **Service** (business logic), **Client** (API abstraction), **Config** (routing & budgets).

**Key Characteristics:**
- Service-oriented architecture with inheritance from `LLM::BaseService`
- Unified client abstraction normalizing OpenAI, Anthropic, and proxy responses
- Task-based routing that maps problem types to cost-optimized models
- Async-by-default using ActiveJob with three queue tiers
- Prompts managed as ERB templates in `app/prompts/` (prompts-as-views pattern)
- Comprehensive cost tracking and budget guardrails per request and daily
- Typed error hierarchy enabling per-error retry/discard strategies
- Result monad pattern for consistent success/failure handling

## Layers

**Service Layer:**
- Purpose: Business logic encapsulation for LLM tasks; where domain-specific validation, prompt rendering, and response parsing happen
- Location: `app/services/llm/`, `app/jobs/llm/`
- Contains: Service objects inheriting from `LLM::BaseService`, job objects inheriting from `LLM::BaseJob`
- Depends on: Client layer (via `LLM::Client.for(model)`), Router (via `LLM::Router.resolve`), Config layer, Cost tracking
- Used by: Controllers (enqueue jobs), models (callbacks), rake tasks, background workers

**Client Layer:**
- Purpose: Normalize provider-specific APIs (ruby-openai, anthropic-rb, LiteLLM/Portkey, test stub) into unified `chat()` interface
- Location: `lib/llm/client.rb`, `lib/llm/clients/`
- Contains: Client factory (`LLM::Client.for(model)`), provider adapters (OpenAI, Anthropic, Proxy, Stub), normalized response handler
- Depends on: Provider gems (ruby-openai, anthropic-rb), Faraday HTTP client, Config for provider selection
- Used by: Service layer only (via factory pattern)

**Infrastructure Layer:**
- Purpose: Routing, cost tracking, token estimation, prompt rendering, configuration loading
- Location: `lib/llm/` (config.rb, router.rb, cost_tracker.rb, token_counter.rb, prompt_renderer.rb)
- Contains: Configuration loader, task-type router, Redis-backed cost tracker, ERB-based prompt renderer, token counter
- Depends on: Rails config, Redis, ERB, YAML
- Used by: Service layer, Client layer (for config), initialization

**Configuration Layer:**
- Purpose: Environment-aware model definitions, routing rules, budget guardrails, API key resolution
- Location: `config/llm.yml`, `config/initializers/llm.rb`
- Contains: Model tiers (cheap/standard/expensive), task routing, daily/per-request budgets, proxy settings, API keys
- Depends on: ENV variables, Rails credentials
- Used by: Router, Client factory, Cost tracker, Token counter

**Template/View Layer:**
- Purpose: Prompt management — user and system prompts as versioned, testable templates
- Location: `app/prompts/`
- Contains: Prompt templates (`.text.erb`, `.system.erb`), partials (`_*.erb`), locale variants (`.es.erb`, `.fr.erb`)
- Depends on: ERB, Rails root, I18n for locale support
- Used by: Service layer (via `LLM::PromptRenderer.render()`)

**Data Models:**
- Purpose: Persistent storage for batches, dead letters, eval cases, experiment logs
- Location: `app/models/llm/`, `db/migrate/`
- Contains: Batch tracking, permanent failure logging, eval dataset storage, shadow experiment results
- Depends on: ActiveRecord
- Used by: Jobs (batch processing, dead letter handling), eval pipeline

## Data Flow

**Synchronous Service Call (Streaming/Real-time):**

1. **Controller/View calls service** → `LLM::ProductDescriptionService.new.call(product: @product)`
2. **Service validates input** → calls `validate_params!(params)`
3. **Service resolves model** → `LLM::Router.resolve(task_type: :generation)` → looks up tier in config → returns model name
4. **Service renders prompt** → `LLM::PromptRenderer.render("product_descriptions/generate", product: @product)` → returns `[{role:, content:}, ...]`
5. **Preflight cost check** → `LLM::TokenCounter.preflight_check!()` → estimates tokens, checks per-request limit
6. **Service gets client** → `LLM::Client.for("gpt-4o")` → factory returns OpenAIClient or ProxyClient based on config
7. **Client calls provider** → normalizes request, calls ruby-openai or Faraday proxy, normalizes response
8. **Service tracks cost** → `CostTrackable#track_cost!()` → records to Redis, checks daily budget
9. **Service parses response** → `parse_response(response)` → extracts domain-specific data
10. **Service returns Result** → `LLM::Result.success(parsed_data, metadata: {model:, cost_usd:, trace_id:, prompt_sha:})`

**Asynchronous Job Flow (Default for Background Tasks):**

1. **Controller enqueues job** → `LLM::GenerateDescriptionJob.perform_later(product.id)`
2. **Sidekiq dequeues job** → from `llm_calls` (or `llm_critical`/`llm_bulk`) queue
3. **Job#perform fetches record** → `product = Product.find(product_id)`
4. **Job calls service** → `LLM::ProductDescriptionService.new.call(product: product)` → full flow above
5. **Job handles success** → stores result in model attributes (e.g., `product.update!(ai_description: @result.value[:description])`)
6. **Job logs cost** → `after_perform` callback records to Rails.logger with trace_id, cost, model
7. **Retry on transient errors** → `retry_on LLM::RateLimitError`, `retry_on LLM::TimeoutError` → exponential backoff
8. **Discard on permanent errors** → `discard_on LLM::ContentFilterError`, `discard_on LLM::BudgetExceededError` → logs to dead letter table
9. **Permanent failure handling** → writes to `llm_dead_letters` table, alerts via Sentry/ErrorNotifier

**Batch Processing Flow:**

1. **Rake task or controller** → `LLM::Batch.enqueue(record_ids: [1,2,3,...], job_class: LLM::BulkDescriptionJob)`
2. **Creates LLM::Batch record** → status: pending
3. **Enqueues single job** → `LLM::BulkDescriptionJob.perform_later(batch_id)`
4. **Job iterates over records** → fetches batch, processes each record with service
5. **Updates progress** → `batch.update!(completed_count:, failed_count:, progress_pct:)`
6. **Records failures** → writes to `batch.failures` for manual review
7. **Job completes** → `batch.update!(status: :completed, finished_at: Time.current)`

**State Management:**

- **In-memory (request scope):** Service instance stores `@trace_id` during execution
- **Redis:** Cost tracker stores daily totals (TTL 7 days), alert flags (TTL 1 day)
- **Database:** Batches, dead letters, eval cases, experiment logs for audit trail and retry capability
- **Result object:** Carries both success/failure state and metadata through service → job → caller

## Key Abstractions

**LLM::BaseService:**
- Purpose: Encapsulate a single LLM task with validation, cost tracking, tracing, and retry logic
- Examples: `LLM::ProductDescriptionService`, `LLM::TicketTriageService`, `LLM::SummarizationService`
- Pattern: Inherit, set `self.task_type`, implement `validate_params!()`, `prompt_template()`, `parse_response()`
- Concerns mixed in: `Traceable` (generates trace_id, logs to TraceLogger), `Retryable` (handles transient errors), `CostTrackable` (estimates cost, checks budget)

**LLM::BaseJob:**
- Purpose: Wrap service calls in async background work with queue strategy, cost logging, permanent failure tracking
- Examples: `LLM::GenerateDescriptionJob`, `LLM::TriageTicketJob`, `LLM::BulkDescriptionJob`
- Pattern: Inherit, set `queue_as` (`:llm_critical`/`:llm_calls`/`:llm_bulk`), override `perform()` to call service and handle result
- Retry strategy: Different backoff for transient errors (RateLimitError, TimeoutError) vs discard for permanent (ContentFilterError, BudgetExceededError)

**LLM::Result:**
- Purpose: Monad-like container for success/failure with consistent metadata
- Pattern: `result = service.call(); result.success? ? result.value : result.error`
- Metadata keys: `{model:, trace_id:, cost_usd:, prompt_sha:}`
- Used throughout to avoid exceptions for expected failures (budget exceeded, content filtered)

**LLM::Client (Factory):**
- Purpose: Unified entry point returning a normalized chat client based on config
- Pattern: `LLM::Client.for(model_name)` → resolves provider from config → returns OpenAIClient, AnthropicClient, ProxyClient, or StubClient
- All clients respond to: `chat(model:, messages:, temperature:, max_tokens:, **options)`
- Normalized response: `{choices: [{message: {role:, content:}}], usage: {input_tokens:, output_tokens:}, model:}`

**LLM::Router:**
- Purpose: Map task type (classification, generation, extraction, reasoning, summarization) to cost-optimized model
- Pattern: `LLM::Router.resolve(task_type: :classification)` → looks up routing in config → returns model name
- Budget check: Pre-flight estimation before routing, raises `BudgetExceededError` if over per-request limit
- Fallback: `LLM::Router.resolve_with_fallback()` → cascade through tiers on failure

**LLM::PromptRenderer:**
- Purpose: Render ERB templates with locals, supporting system/user message separation, partials, and i18n
- Pattern: `LLM::PromptRenderer.render("product_descriptions/generate", product: @product)` → returns `[{role: "system", content: "..."}, {role: "user", content: "..."}]`
- File structure: `.text.erb` (user prompt), `.system.erb` (system prompt, optional), `_partial.erb` (reusable fragments), `.text.es.erb` (locale variants)
- SHA versioning: `current_prompt_sha` stored in Result metadata for traceability

**LLM::CostTracker (Redis-backed):**
- Purpose: Record per-call costs atomically, enforce daily budgets, provide daily/weekly reporting
- Pattern: `LLM::CostTracker.record(service:, model:, input_tokens:, output_tokens:, cost_usd:)` → increments Redis counters
- Queries: `daily_total()`, `daily_breakdown()` (by model/service), `weekly_report()`
- Alert: Triggers once at 80% of daily budget (via threshold_pct config)

**LLM::TokenCounter:**
- Purpose: Estimate tokens before calling API, prevent surprises
- Pattern: `LLM::TokenCounter.preflight_check!(prompt_text:, model_config:)` → raises BudgetExceededError if estimated cost exceeds limit
- Estimation: Rough (4 chars per token) by default, precise with tiktoken_ruby gem optional

## Entry Points

**LLM::BaseService#call:**
- Location: `app/services/llm/base_service.rb` (in templates, used via inheritance in subclasses)
- Triggers: Synchronous calls from controllers/views, or called from jobs
- Responsibilities: Validate input, resolve model, render prompt, preflight budget check, execute LLM call, track cost, parse response, return Result with metadata

**LLM::BaseJob#perform:**
- Location: `app/jobs/llm/base_job.rb` (in templates, used via inheritance in subclasses)
- Triggers: Sidekiq dequeue from one of three queues based on urgency
- Responsibilities: Fetch record(s), call service, handle success (update model), handle failure (retry/discard/log dead letter), log cost after_perform

**LLM::Client.for(model):**
- Location: `lib/llm/client.rb` (generated by installer)
- Triggers: Called only by services during execute_llm_call
- Responsibilities: Route to correct provider client, return normalized response

**LLM::Router.resolve(task_type:):**
- Location: `lib/llm/router.rb` (generated by installer)
- Triggers: Called by services in resolve_model
- Responsibilities: Look up model tier for task type, estimate cost, check budget, return model name

**LLM::PromptRenderer.render(template_name, **locals):**
- Location: `lib/llm/prompt_renderer.rb` (generated by installer)
- Triggers: Called by services in render_prompt
- Responsibilities: Load ERB templates, render with locals, return messages array with system/user separation

## Error Handling

**Strategy:** Typed error hierarchy with per-error retry and alerting strategy.

**Error Taxonomy:**
- `LLM::Error` — Base class
- `LLM::RateLimitError` — Transient, retry with exponential backoff (3-5 attempts)
- `LLM::TimeoutError` — Transient, retry with fixed backoff (2-3 attempts)
- `LLM::ContentFilterError` — Permanent, discard (don't retry), log to dead letter
- `LLM::BudgetExceededError` — Permanent, discard immediately, don't alert (expected)
- `LLM::AuthenticationError` — Permanent, discard, alert (config issue)
- `LLM::InvalidResponseError` — Parsing failure, permanent for that output (discard)

**Patterns:**

In services (`app/services/llm/*.rb`):
```ruby
rescue LLM::BudgetExceededError => e
  LLM::Result.failure(e, trace_id: trace_id)
rescue LLM::Error => e
  LLM::Result.failure(e, trace_id: trace_id)
```

In jobs (`app/jobs/llm/*.rb`):
```ruby
retry_on LLM::RateLimitError, wait: :polynomially_longer, attempts: 5
retry_on LLM::TimeoutError, wait: 30.seconds, attempts: 3
discard_on LLM::ContentFilterError do |job, error|
  job.send(:handle_permanent_failure, error)
end
```

In client layer (`lib/llm/clients/*.rb`):
```ruby
rescue Faraday::TooManyRequestsError => e
  raise LLM::RateLimitError, "..."
rescue Faraday::TimeoutError => e
  raise LLM::TimeoutError, "..."
```

## Cross-Cutting Concerns

**Logging:**
- Trace logger (integrated, called via `Traceable` concern) records every service call with input/output, duration, metadata
- Rails.logger used for cost reporting, job completion, permanent failures
- Sentry integration via `ErrorNotifier` for unhandled exceptions and dead letters

**Validation:**
- Input validation in service (implement `validate_params!()`)
- Schema validation in response parsing (e.g., verify required fields, validate enum values)
- Pre-flight budget validation in Router (per-request max check) and Service (daily total check)

**Authentication:**
- API keys resolved in order: `config/llm.yml` → Rails.application.credentials → ENV variables
- Handled in client layer (OpenAIClient, AnthropicClient), never in services
- Missing key raises `LLM::AuthenticationError` at boot time via initializer validation

**Cost Tracking:**
- Every call through `CostTrackable` concern records token usage and estimated cost to Redis
- Cost calculation uses pricing hash in concern (model name → input_rate, output_rate per 1M tokens)
- Daily budget enforced pre-call (estimated token check in preflight), post-call (actual tokens check in track_cost!)
- Weekly reporting via `LLM::CostTracker.weekly_report()` for dashboards

**Concurrency:**
- Services are stateless, can be instantiated concurrently
- `@trace_id` instance variable per call (request-scoped)
- Redis-backed cost tracker uses atomic increments (HINCRBYFLOAT, HINCRBY in MULTI block)
- Jobs run in Sidekiq workers with concurrency controlled in sidekiq.yml

---

*Architecture analysis: 2026-03-13*

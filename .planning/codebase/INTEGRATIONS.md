# External Integrations

**Analysis Date:** 2026-03-13

## APIs & External Services

**LLM Providers:**
- OpenAI - Chat Completion API for GPT models
  - SDK: `ruby-openai` gem ~7.0
  - Client: `lib/llm/clients/openai_client.rb`
  - Models: gpt-4o, gpt-4o-mini (configurable in `config/llm.yml`)
  - Auth: OPENAI_API_KEY (env var), Rails credentials, or config/llm.yml

- Anthropic - Message API for Claude models
  - SDK: `anthropic` gem ~0.3
  - Client: `lib/llm/clients/anthropic_client.rb`
  - Models: claude-sonnet-4-6, claude-opus-4-6, claude-haiku-4-5 (configurable)
  - Auth: ANTHROPIC_API_KEY (env var), Rails credentials, or config/llm.yml

**Proxy/Gateway (Optional):**
- LiteLLM - Model routing proxy
  - URL: LITELLM_PROXY_URL environment variable
  - Client: `lib/llm/clients/proxy_client.rb` (Faraday-based)
  - Use case: Route between providers, cost optimization, fallback chains
  - Endpoint: POST /chat/completions (OpenAI-compatible)

- Portkey - Managed LLM gateway alternative to LiteLLM
  - URL: Configured in config/llm.yml proxy.base_url
  - Client: `lib/llm/clients/proxy_client.rb` (same as LiteLLM, provider agnostic)
  - Use case: Cost tracking, load balancing, multi-model fallbacks

## Data Storage

**Databases:**
- PostgreSQL (assumed by Rails convention)
  - ORM: ActiveRecord
  - Migrations: Provided in `templates/migrations/`
  - Tables:
    - `llm_batches` - Batch job tracking and status
    - `llm_dead_letters` - Permanent failure logs for discarded jobs
    - `llm_eval_cases` - Eval dataset storage (input, expected output, tags)
    - `llm_experiment_logs` - Shadow experiment results (model A vs B comparisons)

**File Storage:**
- Local filesystem only (prompts committed to git)
  - Location: `app/prompts/` - ERB templates for system/user prompts
  - Versioning: Git version control
  - No S3 or cloud storage integration

**Caching:**
- Redis ~5.0
  - Cost tracking: `llm:costs:{date}` hash with daily spend aggregates
  - Response cache: `llm:cache:{prompt_hash}` with 1-hour TTL
  - Rate limit state: Request counters for exponential backoff
  - Alert tracking: Prevents duplicate budget threshold notifications
  - Key prefix: `llm:costs`, `llm:cache`, `llm:alert`

## Authentication & Identity

**API Authentication:**
- Provider: Multiple (OpenAI, Anthropic, custom proxy)
- Implementation: Per-provider key management
- Key resolution order (in `lib/llm/clients/`):
  1. config/llm.yml `api_keys` section
  2. Rails credentials (e.g., `credentials.openai.api_key`)
  3. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY)
  4. Raises LLM::AuthenticationError if missing
- Auth headers: Bearer token in Authorization header (Faraday)

**Braintrust (Optional):**
- API Key: Rails credentials (braintrust_api_key)
- Configuration: `config/initializers/braintrust.rb`
- Skipped in test environment

## Monitoring & Observability

**Error Tracking:**
- Optional integration with Sentry (checked in `lib/llm/trace_logger.rb`)
- Never lets eval logging break production (rescue and log)
- Error context passed: service class, job ID, arguments

**Logging:**
- Rails logger: Standard logging with structured data
- Braintrust: Optional tracing for LLM calls (see `lib/llm/trace_logger.rb`)
  - Metadata: service, model, trace_id, duration_ms, error, environment, git_sha
  - Project name from ENV["BRAINTRUST_PROJECT"] or Rails app name
  - Conditional: Skipped in test environment

**Cost Tracking:**
- Redis-backed daily aggregates (`lib/llm/cost_tracker.rb`)
- Breakdown by model, service, request count
- Alert threshold: 80% of daily budget (configurable)
- Weekly reports available via `LLM::CostTracker.weekly_report`

## CI/CD & Deployment

**Hosting:**
- Deployment target: Any Rails 7.0+ host (AWS, Heroku, VPS, Kubernetes)
- No specific platform dependencies
- Requires: Ruby 3.0+, Redis, database, and LLM provider API access

**CI Pipeline:**
- Not built into this skill (assumed in consuming app)
- Recommended: Unit tests with WebMock stubs on every commit
- Optional: VCR integration tests (record once, replay in CI)
- Optional: Nightly eval regression gates via Braintrust

**Environment Configuration:**
- Rails.env: development, test, staging, production
- Environment-specific budgets in `config/llm.yml`
- Test environment uses stub provider for deterministic testing

## Environment Configuration

**Required Env Vars:**
- OPENAI_API_KEY - OpenAI API key (if using GPT models)
- ANTHROPIC_API_KEY - Anthropic API key (if using Claude models)
- REDIS_URL - Redis connection string (for cost tracking, caching)
- LITELLM_PROXY_URL - LiteLLM proxy endpoint (only if proxy enabled in config)
- LITELLM_API_KEY - LiteLLM authentication (only if proxy enabled)

**Optional Env Vars:**
- BRAINTRUST_PROJECT - Braintrust project name override (defaults to Rails app name)
- GIT_SHA - Git commit SHA (logged in Braintrust traces for correlation)
- RAILS_ENV - Environment (development/test/staging/production)

**Secrets Location:**
- Primary: Rails encrypted credentials (`config/credentials.yml.enc`)
- Fallback: Environment variables
- Least preferred: Plaintext in `config/llm.yml` (use ERB to read env vars instead)
- Never: Hardcoded API keys

## Webhooks & Callbacks

**Incoming:**
- None - This skill does not expose webhook endpoints

**Outgoing:**
- ActiveJob callbacks: `after_perform`, `discard_on` for error handling
- Braintrust logging: Asynchronous fire-and-forget traces
- Error notifications: Passed to ErrorNotifier (assumed in consuming app)
- Cost alerts: ErrorNotifier.warn when budget threshold reached (see `lib/llm/cost_tracker.rb`)

## Data Flows

**LLM Service Call Flow:**
1. Controller/Job calls LLM service (e.g., `LLM::ProductDescriptionService.new.call`)
2. Service validates parameters (custom override)
3. Service resolves model via `LLM::Router.resolve(task_type:)` from config
4. Service renders prompt from `app/prompts/` ERB template
5. Service calls `LLM::Client.for(model)` - routes to OpenAI, Anthropic, or proxy
6. Client normalizes response to unified shape
7. Service parses response (custom override)
8. Service tracks cost in Redis and checks budgets
9. Service logs trace to Braintrust (optional, async)
10. Service returns Result object (success or failure)

**Cost Tracking Flow:**
1. After every LLM call, tokens are recorded in Redis hash
2. Daily key: `llm:costs:{date}`
3. Aggregates: total, model:X, service:Y, requests, input_tokens, output_tokens
4. Budget check: Raises LLM::BudgetExceededError if daily or per-request limit exceeded
5. Alert: Notified via ErrorNotifier at 80% threshold (once per day)

**Async Job Flow:**
1. Job enqueued to Sidekiq queue (llm_critical, llm_calls, llm_bulk)
2. Job retries on transient errors (RateLimitError, TimeoutError) with exponential backoff
3. Job discards on permanent failures (ContentFilterError, AuthenticationError, BudgetExceededError)
4. Failed job logged to `llm_dead_letters` table
5. Error notified via ErrorNotifier

**Eval Pipeline Flow (Optional):**
1. Every LLM call generates trace in Braintrust (async, doesn't block)
2. Production traces accumulate in Braintrust dashboard
3. Humans annotate traces with expected outputs and scores
4. Dataset exported from Braintrust for eval runs
5. Eval scoring: LLM-as-judge or custom functions
6. Results logged back to Braintrust
7. CI regression gates: Deploy blocked if quality degraded

## Integration Points with Rails App

**Required Integrations:**
- ActiveJob backend (Sidekiq recommended, but any AJ adapter works)
- Redis instance
- Database (migrations provided)
- One or more LLM provider API keys

**Optional Integrations:**
- Braintrust (for eval pipeline)
- Sentry (for error tracking)
- ErrorNotifier (for budget alerts)
- LiteLLM/Portkey proxy (for cost optimization)

**Generated Files (from generators):**
- `app/services/llm/base_service.rb` - Base class with Traceable, Retryable, CostTrackable
- `app/jobs/llm/base_job.rb` - Base job class with retry/discard rules
- `config/llm.yml` - LLM configuration (environment-specific)
- `config/initializers/llm.rb` - Boot-time config validation
- Database migrations for batches, dead letters, eval cases, experiment logs
- Service/job generators: `rails generate llm:service`, `rails generate llm:job`

---

*Integration audit: 2026-03-13*

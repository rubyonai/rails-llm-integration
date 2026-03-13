# Technology Stack

**Analysis Date:** 2026-03-13

## Languages

**Primary:**
- Ruby 3.0+ - Core skill framework and Rails integration patterns
- YAML - Configuration files (`config/llm.yml`)
- ERB - Prompt templates (`app/prompts/`)

**Secondary:**
- SQL - Database migrations for batch tracking, eval cases, dead letter queues

## Runtime

**Environment:**
- Ruby on Rails 7.0+ - Web framework (provides generators, initializers, credentials)
- ActiveJob - Background job framework with multiple queue support
- Sidekiq - Recommended job backend (see `references/job-patterns.md`)

**Package Manager:**
- Bundler (Ruby gemfile dependency manager)
- Lockfile: Assumed present in consuming Rails applications

## Frameworks

**Core:**
- Ruby on Rails 7.0+ - Web application framework
- ActiveJob - Background job processing

**LLM Clients:**
- `ruby-openai` ~7.0 - OpenAI API wrapper (`lib/llm/clients/openai_client.rb`)
- `anthropic` ~0.3 - Anthropic Claude API wrapper (`lib/llm/clients/anthropic_client.rb`)
- `faraday` ~2.0 - HTTP client for direct API calls and proxy routing (`lib/llm/clients/proxy_client.rb`)

**Testing:**
- RSpec - Rails testing framework (assumed in consuming applications)
- WebMock - HTTP stub/mock library for unit tests
- VCR - HTTP recording for integration test fixtures

**Evaluation:**
- `braintrust` ~0.1 (optional) - LLM evaluation and tracing pipeline (`lib/llm/trace_logger.rb`)

**Build/Dev:**
- Rails generators - CLI for scaffolding (`scripts/generators.md`)

## Key Dependencies

**Critical:**
- `ruby-openai` ~7.0 - OpenAI API integration (required for GPT models)
- `anthropic` ~0.3 - Anthropic Claude API integration (required for Claude models)
- `faraday` ~2.0 - HTTP client with timeout and error handling (required for all API calls)
- `redis` ~5.0 - Cost tracking, rate limit state, response caching (`lib/llm/cost_tracker.rb`)

**Infrastructure:**
- `braintrust` ~0.1 - Optional eval pipeline integration (`lib/llm/trace_logger.rb`)
- `tiktoken_ruby` - Optional precise token counting (defaults to 4-char-per-token estimate)

## Configuration

**Environment:**
- Loaded from `config/llm.yml` - ERB-templated YAML configuration (see `templates/llm.yml.tt`)
- ERB.new().result() enables embedded Ruby - API keys from credentials/ENV
- Rails credentials integration - Secrets via Rails.application.credentials
- ENV variable fallback - Keys read from OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.

**API Key Resolution Order (in `lib/llm/clients/`):**
1. `config/llm.yml` values
2. Rails credentials (e.g., `credentials.openai.api_key`)
3. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY)
4. Raises LLM::AuthenticationError if all missing

**Build:**
- Rails generator templates in `templates/` - Scaffolding for new services/jobs
- Migration templates in `templates/migrations/` - Database schema for LLM tracking tables
- YAML config template in `templates/llm.yml.tt` - Environment-specific LLM configuration

## Platform Requirements

**Development:**
- Ruby 3.0+
- Rails 7.0+
- Bundler
- Redis server (for cost tracking, rate limiting, caching)
- One or more LLM provider accounts (OpenAI and/or Anthropic)
- Valid API keys for OpenAI and/or Anthropic in environment variables

**Production:**
- Same as development plus:
- Sidekiq or compatible ActiveJob backend for async LLM calls
- Redis instance (shared across workers)
- Optional: LiteLLM or Portkey proxy server (for model routing and cost optimization)
- Daily budget guardrails enforced via `LLM::CostTracker` and `LLM::Config`

## Database

**Migrations Required (from `templates/migrations/`):**
- `create_llm_batches` - Tracks batch job executions and completions
- `create_llm_dead_letters` - Permanent failure logs for discarded LLM jobs
- `create_llm_eval_cases` - Eval dataset storage for Braintrust integration
- `create_llm_experiment_logs` - Shadow experiment results (model A vs B)

## Key Configuration Files

**`config/llm.yml` (ERB-templated):**
- Models section: Defines cheap/standard/expensive tiers with provider and model name
- Routing section: Maps task_type (classification/generation/reasoning) to model tier
- Budget section: daily_budget_usd, per_request_max_usd, alert_threshold_pct
- Proxy section: Optional LiteLLM/Portkey configuration
- API keys section: Provider keys (prefer credentials/ENV over this file)
- Environment-specific overrides: development uses lower budgets, test uses stub provider

**`config/initializers/llm.rb` (optional):**
- Loads and validates `LLM.config` at boot time
- Validates required API keys are present in production

## Caching & Storage

**Redis:**
- Cost tracking: `llm:costs:{date}` hash stores daily spend by model/service
- Response cache: `llm:cache:{prompt_hash}` stores LLM responses (1 hour TTL)
- Rate limit state: Request tracking for backoff calculation
- Alert throttling: Prevents duplicate budget threshold alerts

**File-based:**
- Prompts: ERB templates in `app/prompts/` (versioned in git)
- Database: ActiveRecord for eval cases, experiment logs, dead letters

## Error Handling Stack

**Error Hierarchy (`app/services/llm/errors.rb`):**
- LLM::Error - Base class
  - LLM::RateLimitError - 429 responses, provider rate limiting
  - LLM::TimeoutError - Network timeouts, slow API responses
  - LLM::ContentFilterError - Safety filters triggered
  - LLM::BudgetExceededError - Daily or per-request limit exceeded
  - LLM::InvalidResponseError - Unparseable LLM output
  - LLM::AuthenticationError - Invalid/missing API keys

**Mapping from HTTP errors:**
- Faraday::TooManyRequestsError → LLM::RateLimitError
- Faraday::TimeoutError, Net::OpenTimeout → LLM::TimeoutError
- HTTP 401/403 → LLM::AuthenticationError
- HTTP 400 with content_filter type → LLM::ContentFilterError

---

*Stack analysis: 2026-03-13*

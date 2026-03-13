# Coding Conventions

**Analysis Date:** 2025-03-13

## Naming Patterns

**Files:**
- Service objects: `{feature_name}_service.rb` → `product_description_service.rb`, `ticket_triage_service.rb`
- Job classes: `{action}_{domain}_job.rb` → `generate_description_job.rb`, `triage_ticket_job.rb`
- Models: Standard Rails convention, `llm_batch.rb`, `llm_dead_letter.rb`
- Templates: `{action}.text.erb` and `{action}.system.erb` → `generate.text.erb`, `generate.system.erb`
- Partials: `_{name}.text.erb` → `_examples.text.erb`, `_json_format.text.erb`
- Concern modules: descriptive names in `concerns/` directory → `traceable.rb`, `retryable.rb`, `cost_trackable.rb`
- Client classes: `{provider}_client.rb` → `openai_client.rb`, `anthropic_client.rb`, `proxy_client.rb`

**Functions:**
- Snake case throughout: `with_tracing`, `execute_llm_call`, `parse_response`, `track_cost!`
- Private methods: Prefixed with `private` keyword (not underscore prefix)
- Predicate methods use `?` suffix: `success?`, `failure?`, `exist?`
- Methods that mutate state/side effects use `!` suffix: `check_budget!`, `track_cost!`, `validate_params!`, `resolve!`, `update!`
- Render/template methods: `render_prompt`, `render_text`, `render_template`
- Validation methods: `validate_params!`, `validate_schema!`

**Variables:**
- Instance variables for mutable state: `@result`, `@trace_id`, `@client`, `@connection`
- Local variables for computed values: `model`, `cost`, `prompt`, `response`
- Constants for fixed config: `PRICING`, `VALID_CATEGORIES`, `MAX_TOKENS_DEFAULT`, `SEVERITY_COLORS`
- Abbreviated but clear: `msg`, `idx`, `attr`, `config`, `params`

**Types:**
- Service/Job base classes: Module-namespaced `LLM::BaseService`, `LLM::BaseJob`
- Error classes: `LLM::Error`, `LLM::RateLimitError`, `LLM::TimeoutError`, `LLM::ContentFilterError`
- Result wrapper: `LLM::Result` (immutable monad-like pattern)
- Concern modules: `LLM::Concerns::Traceable`, `LLM::Concerns::Retryable`, `LLM::Concerns::CostTrackable`
- Config class: `LLM::Config` (singleton-like, accessed via `LLM.config`)
- Client types: `LLM::Client`, `LLM::OpenAIClient`, `LLM::AnthropicClient`, `LLM::ProxyClient`, `LLM::StubClient`

## Code Style

**Formatting:**
- All files use `# frozen_string_literal: true` at the top
- Indentation: 2 spaces (Ruby standard)
- Line length: Soft wrap at 100 columns, hard limit 120
- Hash literals: Modern hash syntax with symbols `{ key: value }`
- Method parameters: Keyword-only arguments preferred `def call(**params)`
- Range literals: Use `(0..)` or `(0...10)` syntax

**Linting:**
- Style guide: Follows Rails/Ruby conventions (implied, no explicit `.rubocop.yml` shown)
- Comments: Explain "why", not "what" (code is self-documenting)
- Module/class comments: Use Ruby doc comments with usage examples
- Inline comments: Sparse, only for non-obvious logic
- Comment blocks: Use `# ---` dividers for section separation

## Import Organization

**Order:**
1. Standard library: `require "openai"`, `require "pathname"`
2. Rails/Gems: `require "anthropic"`, `require "faraday"`, `require "vcr"`
3. Local requires (rarely needed due to autoloading): None visible in conventions
4. Module/class definition: After all requires

**Path Aliases:**
- Rails autoloads `app/services/`, `app/jobs/`, `app/models/` automatically
- Namespaced under `LLM::` module: `LLM::BaseService`, `LLM::ProductDescriptionService`
- Library code lives in `lib/llm/` and is autoloaded via Rails
- No explicit `require_relative` or custom load paths

## Error Handling

**Patterns:**
- Define error taxonomy upfront: `app/services/llm/errors.rb` (see `service-patterns.md` for standard hierarchy)
- Typed errors: `LLM::RateLimitError`, `LLM::TimeoutError`, `LLM::ContentFilterError`, `LLM::BudgetExceededError`, `LLM::InvalidResponseError`, `LLM::AuthenticationError`
- Rescue specific error classes, never bare `rescue Exception`
- Map HTTP/network errors to typed errors: `Faraday::TooManyRequestsError` → `LLM::RateLimitError`
- Return `LLM::Result.failure(error)` from services, never raise from public API
- Private methods raise exceptions; public methods return Result
- Budget checks before execution: `check_budget!` in `CostTrackable` concern
- API key resolution follows strict precedence: config/llm.yml → Rails credentials → ENV vars

Example error handling in clients (from `client-setup.md`):
```ruby
rescue Faraday::TooManyRequestsError
  raise LLM::RateLimitError, "Rate limited by #{model}"
rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout
  raise LLM::TimeoutError, "Timeout calling #{model}"
```

## Logging

**Framework:** Rails.logger (standard Rails approach)

**Patterns:**
- Structured logging with key-value pairs: `Rails.logger.info("LLM Job Cost", job_class: self.class.name, cost_usd: cost)`
- Log before/after LLM calls via `Traceable` concern
- Log cost tracking after every successful call
- Error logging goes through concern methods: `log_trace(trace_data)` in Traceable
- Integration with Braintrust for LLM-specific tracing: `LLM::TraceLogger.log(trace_data)`
- Permanent failures logged with full context: `Rails.logger.error("LLM Job Permanently Failed", ...)`
- Logs include: `trace_id`, `service`, `model`, `cost_usd`, `duration_ms`, `error_class`, `error_message`

## Comments

**When to Comment:**
- Explain surprising design choices ("Why we extract system prompt separately for Anthropic")
- Document public API contracts: service methods with usage examples
- Mark TODOs sparingly, only for known blockers
- Schema migrations: include inline explanation of table purpose

**JSDoc/TSDoc:**
- Use Ruby doc comments (not typical Ruby convention) for public methods
- Example from templates:
```ruby
# LLM::BaseService — Base class for all LLM service objects
#
# Usage:
#   class LLM::ProductDescriptionService < LLM::BaseService
#     self.task_type = :generation
#   end
#   result = LLM::ProductDescriptionService.new.call(product: product)
```
- Concerns include section dividers with descriptive headings:
```ruby
# -------------------------------------------------------------------
# Public API — call(**params) -> LLM::Result
# -------------------------------------------------------------------
```

## Function Design

**Size:**
- Public `call` methods: 15-30 lines max (delegate to private helpers)
- Concern hooks (like `with_tracing`, `with_retries`): 20-40 lines (wrapping behavior)
- Private helper methods: 5-15 lines (single responsibility)
- Response normalization: 10-20 lines per client

**Parameters:**
- Service methods: Accept `**params` (keyword splatting for flexibility)
- Use `validate_params!` to guard before execution
- Pass discrete values to private methods, not the params hash
- Client `chat` method: `(model:, messages:, temperature: 0.0, max_tokens: 1024, **options)`
- Job `perform` method: Pass record IDs only, never serialized objects

**Return Values:**
- Public service methods: Always return `LLM::Result` (success or failure)
- Private methods: Can raise or return normally
- Prompt renderers: Return array of message hashes or raw text string
- Normalized responses: Hash with consistent shape `{ choices: [...], usage: {...}, model: "..." }`
- Job `perform`: Implicitly returns nil (side effects on Model updates)

## Module Design

**Exports:**
- Services: No explicit exports (Rails autoloads)
- Concerns: Mixed into services via `include`: `include Concerns::Traceable`
- Clients: Factory pattern exposes them: `LLM::Client.for(model)`
- Config: Singleton-like access: `LLM.config`

**Barrel Files:**
- Avoid excessive index/barrel files
- Services are namespaced: `LLM::ProductDescriptionService` lives in `app/services/llm/product_description_service.rb`
- Errors defined centrally in `app/services/llm/errors.rb` (single file)
- Concerns in `app/services/llm/concerns/` (one file per concern)

**Module Nesting:**
- All LLM code is under `module LLM` namespace
- Submodules: `LLM::Concerns::*`, `LLM::Clients::*` (not visible in examples, but inferred)
- ApplicationJob and ApplicationRecord stay at top level (Rails standard)

## Service Conventions

Services follow an explicit contract:

```ruby
class LLM::ProductDescriptionService < LLM::BaseService
  self.task_type = :generation      # Declare the task type
  self.max_retries = 2              # Override if needed

  private

  def validate_params!(params)       # Required: guard input
    raise ArgumentError, "..." unless params[:product]
  end

  def prompt_template                # Required: template path
    "product_descriptions/generate"
  end

  def parse_response(response)       # Required: extract value from response
    # Extract from normalized response shape
    content = response.dig(:choices, 0, :message, :content)
    { title: ..., description: ... }
  end

  def temperature                    # Optional: override defaults
    0.7
  end

  def max_tokens                     # Optional: override defaults
    512
  end
end
```

Each service:
- Inherits from `LLM::BaseService` (brings `Traceable`, `Retryable`, `CostTrackable`)
- Declares `task_type` as class attribute (used by router for model selection)
- Implements three required hooks: `validate_params!`, `prompt_template`, `parse_response`
- Calls `super` via `call(**params)` which handles retry/tracing/cost logic
- Returns `LLM::Result` always

## Job Conventions

Jobs follow an explicit queue/retry strategy:

```ruby
class LLM::GenerateDescriptionJob < LLM::BaseJob
  queue_as :llm_calls              # One of :llm_critical, :llm_calls, :llm_bulk

  def perform(product_id)
    product = Product.find(product_id)
    @result = LLM::ProductDescriptionService.new.call(product: product)

    if @result.success?
      product.update!(ai_description: @result.value[:description])
    else
      raise @result.error           # Triggers BaseJob retry logic
    end
  end
end
```

Each job:
- Inherits from `LLM::BaseJob` (brings retry/discard strategy, logging)
- Declares `queue_as` matching urgency
- Accepts record IDs (not models) in `perform`
- Stores result in `@result` for logging
- Raises on failure to trigger retries
- BaseJob handles permanent failures via `discard_on` callbacks

## Template Rendering Conventions

Prompts use ERB templates with locals:

```erb
<%# app/prompts/product_descriptions/generate.system.erb %>
You are an expert product copywriter...

<%# app/prompts/product_descriptions/generate.text.erb %>
Write a description for: <%= @product.name %>
<% if @tone -%>
Tone: <%= @tone %>
<% end -%>
```

Each prompt:
- System prompt in separate `.system.erb` file (optional)
- User prompt in `.text.erb` file (required)
- Locals passed as `**params` (converted to instance variables)
- Conditionals use ERB `-` trim mode
- Rendered via `LLM::PromptRenderer.render(template_name, **locals)`
- No hardcoded prompts in code (anti-pattern flagged by audit script)

## Configuration Conventions

Configuration lives in `config/llm.yml` (YAML file):

```yaml
models:
  cheap:
    model: "gpt-4o-mini"
    provider: "openai"
  powerful:
    model: "gpt-4"
    provider: "openai"

daily_budget_usd: 100.0
per_request_max_usd: 10.0
```

Access via `LLM.config`:
- `LLM.config.daily_budget_usd`
- `LLM.config.provider_for(model_name)`
- `LLM.config.api_key_for(provider)`
- `LLM.config.route_for(task_type)`

---

*Convention analysis: 2025-03-13*

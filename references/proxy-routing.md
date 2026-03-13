# Proxy Routing & Cost Optimization

Model routing, budget guardrails, and cost optimization. This is where you save 80%
of your LLM spend.

## config/llm.yml

Like `database.yml` but for LLM providers:

```yaml
# config/llm.yml
default: &default
  proxy:
    enabled: false
    # provider: litellm  # or "portkey"
    # base_url: http://localhost:4000

  daily_budget_usd: 50.00
  per_request_max_usd: 0.50
  alert_threshold_pct: 80  # Alert at 80% of daily budget

  models:
    cheap:
      provider: openai
      model: gpt-4o-mini
      max_tokens: 4096
      cost_per_1m_input: 0.15
      cost_per_1m_output: 0.60
    standard:
      provider: anthropic
      model: claude-sonnet-4-6
      max_tokens: 8192
      cost_per_1m_input: 3.00
      cost_per_1m_output: 15.00
    expensive:
      provider: anthropic
      model: claude-opus-4-6
      max_tokens: 4096
      cost_per_1m_input: 15.00
      cost_per_1m_output: 75.00

  routing:
    classification: cheap
    extraction: cheap
    generation: standard
    summarization: standard
    reasoning: expensive

  fallback_chain:
    - standard
    - cheap
    - cached

  # Provider API keys (prefer Rails credentials or ENV over this file)
  api_keys:
    openai: <%= ENV["OPENAI_API_KEY"] %>
    anthropic: <%= ENV["ANTHROPIC_API_KEY"] %>

development:
  <<: *default
  daily_budget_usd: 5.00
  per_request_max_usd: 0.10

test:
  <<: *default
  daily_budget_usd: 0.00
  models:
    cheap:
      provider: stub
      model: test-model
    standard:
      provider: stub
      model: test-model
    expensive:
      provider: stub
      model: test-model

staging:
  <<: *default
  daily_budget_usd: 20.00

production:
  <<: *default
  daily_budget_usd: 500.00
  per_request_max_usd: 2.00
  proxy:
    enabled: true
    provider: litellm
    base_url: <%= ENV["LITELLM_PROXY_URL"] %>
```

## LLM Configuration Loader

```ruby
# lib/llm/config.rb
module LLM
  class Config
    def initialize
      @config = YAML.safe_load(
        ERB.new(Rails.root.join("config", "llm.yml").read).result,
        permitted_classes: [],
        aliases: true
      ).fetch(Rails.env)
    end

    def daily_budget_usd
      @config.fetch("daily_budget_usd")
    end

    def per_request_max_usd
      @config.fetch("per_request_max_usd")
    end

    def model_for(tier)
      @config.dig("models", tier.to_s) || raise("Unknown model tier: #{tier}")
    end

    def route_for(task_type)
      tier = @config.dig("routing", task_type.to_s) || "standard"
      model_for(tier)
    end

    def proxy_config
      @config.fetch("proxy", {})
    end

    def fallback_chain
      @config.fetch("fallback_chain", ["standard"])
    end

    def alert_threshold_pct
      @config.fetch("alert_threshold_pct", 80)
    end

    def provider_for(model_name)
      models = @config.fetch("models", {})
      models.each do |_tier, config|
        return config["provider"] if config["model"] == model_name
      end
      raise LLM::Error, "Model '#{model_name}' not found in config/llm.yml"
    end

    def api_key_for(provider)
      @config.dig("api_keys", provider)
    end
  end

  def self.config
    @config ||= Config.new
  end

  def self.reload_config!
    @config = Config.new
  end
end
```

## Router

Task-based routing -- cheap tasks go to cheap models:

```ruby
# lib/llm/router.rb
module LLM
  class Router
    # Resolve which model to use for a given task type
    def self.resolve(task_type:)
      config = LLM.config.route_for(task_type)
      model_name = config.fetch("model")

      # Pre-flight budget check
      estimated_cost = estimate_request_cost(config)
      if estimated_cost > LLM.config.per_request_max_usd
        raise LLM::BudgetExceededError,
          "Estimated cost $#{'%.4f' % estimated_cost} exceeds per-request max"
      end

      model_name
    end

    # Resolve with fallback chain on failure
    def self.resolve_with_fallback(task_type:)
      primary = resolve(task_type: task_type)

      FallbackChain.new(
        primary: primary,
        fallbacks: LLM.config.fallback_chain.map { |tier|
          LLM.config.model_for(tier).fetch("model")
        }
      )
    end

    private_class_method def self.estimate_request_cost(config)
      # Conservative estimate: 1000 input tokens, 500 output tokens
      input_cost = 1000 * config.fetch("cost_per_1m_input", 0) / 1_000_000.0
      output_cost = 500 * config.fetch("cost_per_1m_output", 0) / 1_000_000.0
      input_cost + output_cost
    end
  end
end
```

## Fallback Chain

When the primary model fails, cascade through alternatives:

```ruby
# lib/llm/fallback_chain.rb
module LLM
  class FallbackChain
    attr_reader :primary, :fallbacks

    def initialize(primary:, fallbacks:)
      @primary = primary
      @fallbacks = fallbacks.reject { |f| f == primary }
    end

    def execute(&block)
      try_model(primary, &block)
    rescue LLM::RateLimitError, LLM::TimeoutError => primary_error
      fallbacks.each do |fallback_model|
        result = try_model(fallback_model, &block)
        return result if result
      rescue LLM::Error
        next
      end

      # All fallbacks exhausted -- try cache
      cached = LLM::ResponseCache.get(block.binding)
      return cached if cached

      raise primary_error  # Re-raise original error
    end

    private

    def try_model(model, &block)
      Rails.logger.info("LLM Routing: attempting #{model}")
      yield(model)
    end
  end
end
```

## Cost Tracker (Redis-backed)

```ruby
# lib/llm/cost_tracker.rb
module LLM
  class CostTracker
    REDIS_KEY_PREFIX = "llm:costs"

    class << self
      def record(service:, model:, input_tokens:, output_tokens:, cost_usd:)
        key = daily_key
        Redis.current.multi do |r|
          r.hincrbyfloat(key, "total", cost_usd)
          r.hincrbyfloat(key, "model:#{model}", cost_usd)
          r.hincrbyfloat(key, "service:#{service}", cost_usd)
          r.hincrby(key, "requests", 1)
          r.hincrby(key, "input_tokens", input_tokens)
          r.hincrby(key, "output_tokens", output_tokens)
          r.expire(key, 7.days.to_i)
        end

        check_alert_threshold!
      end

      def daily_total
        Redis.current.hget(daily_key, "total").to_f
      end

      def daily_breakdown
        Redis.current.hgetall(daily_key).transform_values(&:to_f)
      end

      def weekly_report
        (0..6).map { |days_ago|
          date = Date.current - days_ago
          key = "#{REDIS_KEY_PREFIX}:#{date}"
          data = Redis.current.hgetall(key)
          { date: date, total_usd: data["total"].to_f, requests: data["requests"].to_i }
        }
      end

      private

      def daily_key
        "#{REDIS_KEY_PREFIX}:#{Date.current}"
      end

      def check_alert_threshold!
        total = daily_total
        budget = LLM.config.daily_budget_usd
        threshold = LLM.config.alert_threshold_pct / 100.0

        if total > budget * threshold
          alert_key = "#{REDIS_KEY_PREFIX}:alert:#{Date.current}"
          unless Redis.current.exists?(alert_key)
            Redis.current.setex(alert_key, 1.day.to_i, "1")
            ErrorNotifier.warn(
              "LLM daily spend at #{'%.0f' % (total / budget * 100)}% " \
              "($#{'%.2f' % total} / $#{'%.2f' % budget})"
            )
          end
        end
      end
    end
  end
end
```

## Token Counting

Estimate tokens before calling the API:

```ruby
# lib/llm/token_counter.rb
module LLM
  class TokenCounter
    # Rough estimate: 1 token ~= 4 characters for English text
    # For precise counting, use tiktoken-ruby gem
    CHARS_PER_TOKEN = 4

    def self.estimate(text)
      (text.to_s.length / CHARS_PER_TOKEN.to_f).ceil
    end

    def self.estimate_cost(text:, model_config:)
      tokens = estimate(text)
      tokens * model_config.fetch("cost_per_1m_input", 0) / 1_000_000.0
    end

    # Pre-flight check: will this request blow the budget?
    def self.preflight_check!(prompt_text:, model_config:)
      estimated_input = estimate(prompt_text)
      estimated_output = [estimated_input / 2, 500].max  # Conservative estimate

      input_cost = estimated_input * model_config.fetch("cost_per_1m_input", 0) / 1_000_000.0
      output_cost = estimated_output * model_config.fetch("cost_per_1m_output", 0) / 1_000_000.0
      total = input_cost + output_cost

      if total > LLM.config.per_request_max_usd
        raise LLM::BudgetExceededError,
          "Estimated cost $#{'%.4f' % total} exceeds limit of $#{LLM.config.per_request_max_usd}"
      end

      { estimated_input_tokens: estimated_input, estimated_cost_usd: total }
    end
  end
end
```

## Shadow Experiment Pattern

Run a cheap model alongside an expensive one. Compare outputs without affecting users:

```ruby
# lib/llm/shadow_experiment.rb
module LLM
  class ShadowExperiment
    attr_reader :name, :primary_model, :shadow_model, :sample_rate

    def initialize(name:, primary_model:, shadow_model:, sample_rate: 0.1)
      @name = name
      @primary_model = primary_model
      @shadow_model = shadow_model
      @sample_rate = sample_rate
    end

    def run(prompt:, &score_fn)
      # Always run primary
      primary_result = execute_model(primary_model, prompt)

      # Run shadow on sample_rate % of requests
      if rand < sample_rate
        shadow_result = execute_model(shadow_model, prompt)
        compare_and_log(primary_result, shadow_result, prompt, &score_fn)
      end

      primary_result  # Always return primary result to user
    end

    private

    def execute_model(model, prompt)
      client = LLM::Client.for(model)
      client.chat(model: model, messages: prompt)
    end

    def compare_and_log(primary, shadow, prompt, &score_fn)
      primary_output = primary.dig(:choices, 0, :message, :content)
      shadow_output = shadow.dig(:choices, 0, :message, :content)

      # Score both outputs (LLM-as-judge or custom function)
      primary_score = score_fn ? score_fn.call(primary_output) : nil
      shadow_score = score_fn ? score_fn.call(shadow_output) : nil

      LLM::ExperimentLog.create!(
        experiment_name: name,
        primary_model: primary_model,
        shadow_model: shadow_model,
        prompt_hash: Digest::SHA256.hexdigest(prompt.to_json),
        primary_output: primary_output,
        shadow_output: shadow_output,
        primary_score: primary_score,
        shadow_score: shadow_score,
        primary_cost: estimate_cost(primary),
        shadow_cost: estimate_cost(shadow)
      )
    end

    def estimate_cost(response)
      tokens = response.dig(:usage)
      return 0 unless tokens
      # Simplified -- real implementation uses model-specific pricing
      (tokens[:input_tokens].to_i + tokens[:output_tokens].to_i) * 0.000003
    end
  end
end
```

Usage:

```ruby
experiment = LLM::ShadowExperiment.new(
  name: "triage_cheap_vs_standard",
  primary_model: "claude-sonnet-4-6",
  shadow_model: "gpt-4o-mini",
  sample_rate: 0.2
)

result = experiment.run(prompt: messages) { |output|
  # Score: does it contain a valid category?
  TicketTriageService::VALID_CATEGORIES.any? { |c| output.include?(c) } ? 1.0 : 0.0
}
```

## Client Layer

The full client implementation (OpenAI, Anthropic, proxy, stub) is in
`references/client-setup.md`. The client factory routes to the right provider:

```ruby
# lib/llm/client.rb — see references/client-setup.md for full implementation
LLM::Client.for("gpt-4o-mini")      # => OpenAIClient (wraps ruby-openai gem)
LLM::Client.for("claude-sonnet-4-6")   # => AnthropicClient (wraps anthropic-rb gem)
# With proxy enabled in config/llm.yml:
LLM::Client.for("any-model")        # => ProxyClient (Faraday to LiteLLM/Portkey)
# In test environment:
LLM::Client.for("test-model-cheap") # => StubClient (deterministic test double)
```

All clients return the same normalized response shape so services never
care which provider is behind the call.

## Response Cache

Last resort in fallback chain -- serve cached responses:

```ruby
# lib/llm/response_cache.rb
module LLM
  class ResponseCache
    TTL = 1.hour

    def self.get(prompt_hash)
      cached = Redis.current.get("llm:cache:#{prompt_hash}")
      JSON.parse(cached, symbolize_names: true) if cached
    end

    def self.set(prompt_hash, response)
      Redis.current.setex(
        "llm:cache:#{prompt_hash}",
        TTL.to_i,
        response.to_json
      )
    end

    def self.cache_key(messages)
      Digest::SHA256.hexdigest(messages.to_json)
    end
  end
end
```

## Key Rules

1. **Cheap tasks get cheap models** -- Classification doesn't need GPT-4
2. **Always estimate cost before calling** -- Preflight checks prevent surprise bills
3. **Budget guardrails are non-negotiable** -- Daily and per-request limits
4. **Shadow experiments prove routing decisions** -- Don't guess, measure
5. **Cache is the cheapest model** -- Use it as the last fallback
6. **Monitor daily** -- Weekly cost reports, alert at 80% budget

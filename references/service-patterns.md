# LLM Service Patterns

The Rails convention for LLM service objects. Every LLM call in your app goes through
a service that inherits from `LLM::BaseService`. This pattern works identically whether
you're using ruby_llm, langchain-rb, ruby-openai, or anthropic-rb — the client layer
handles the gem, the service layer handles your business logic.

## Error Taxonomy

Define these in `app/services/llm/errors.rb`:

```ruby
# app/services/llm/errors.rb
module LLM
  class Error < StandardError; end
  class RateLimitError < Error; end
  class TimeoutError < Error; end
  class ContentFilterError < Error; end
  class BudgetExceededError < Error; end
  class InvalidResponseError < Error; end
  class AuthenticationError < Error; end
end
```

## Result Object

Use a simple Result pattern (no gem required):

```ruby
# app/services/llm/result.rb
module LLM
  class Result
    attr_reader :value, :error, :metadata

    def initialize(value: nil, error: nil, metadata: {})
      @value = value
      @error = error
      @metadata = metadata
    end

    def success? = error.nil?
    def failure? = !success?

    def self.success(value, **metadata)
      new(value: value, metadata: metadata)
    end

    def self.failure(error, **metadata)
      new(error: error, metadata: metadata)
    end
  end
end
```

## Concerns

### Traceable

Logs every call to Braintrust (or any logger):

```ruby
# app/services/llm/concerns/traceable.rb
module LLM
  module Concerns
    module Traceable
      extend ActiveSupport::Concern

      included do
        attr_reader :trace_id
      end

      private

      def with_tracing(input:, &block)
        @trace_id = SecureRandom.uuid
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        result = yield

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

        log_trace(
          trace_id: @trace_id,
          service: self.class.name,
          input: input,
          output: result.success? ? result.value : nil,
          error: result.failure? ? result.error.message : nil,
          duration_ms: (duration * 1000).round,
          metadata: result.metadata
        )

        result
      end

      def log_trace(trace_data)
        LLM::TraceLogger.log(trace_data)
      end
    end
  end
end
```

### Retryable

Automatic retry with exponential backoff for transient errors:

```ruby
# app/services/llm/concerns/retryable.rb
module LLM
  module Concerns
    module Retryable
      extend ActiveSupport::Concern

      included do
        class_attribute :max_retries, default: 3
        class_attribute :base_delay, default: 1.0
        class_attribute :retryable_errors, default: [
          LLM::RateLimitError,
          LLM::TimeoutError,
          Net::OpenTimeout,
          Net::ReadTimeout
        ]
      end

      private

      def with_retries(&block)
        attempts = 0
        begin
          attempts += 1
          yield
        rescue *retryable_errors => e
          raise if attempts >= max_retries

          delay = base_delay * (2**(attempts - 1)) + rand(0.0..0.5)
          sleep(delay)
          retry
        end
      end
    end
  end
end
```

### CostTrackable

Estimates and records cost per call:

```ruby
# app/services/llm/concerns/cost_trackable.rb
module LLM
  module Concerns
    module CostTrackable
      extend ActiveSupport::Concern

      # Cost per 1M tokens (update as pricing changes)
      PRICING = {
        "gpt-4o" =>          { input: 2.50, output: 10.00 },
        "gpt-4o-mini" =>     { input: 0.15, output: 0.60 },
        "claude-sonnet-4-6" =>  { input: 3.00, output: 15.00 },
        "claude-haiku-4-5" => { input: 0.80, output: 4.00 },
      }.freeze

      private

      def estimate_cost(model:, input_tokens:, output_tokens:)
        pricing = PRICING.fetch(model) { return 0.0 }
        (input_tokens * pricing[:input] + output_tokens * pricing[:output]) / 1_000_000.0
      end

      def track_cost!(model:, input_tokens:, output_tokens:)
        cost = estimate_cost(model: model, input_tokens: input_tokens, output_tokens: output_tokens)
        LLM::CostTracker.record(
          service: self.class.name,
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_usd: cost
        )
        check_budget!(cost)
        cost
      end

      def check_budget!(cost)
        daily_total = LLM::CostTracker.daily_total
        daily_limit = LLM.config.daily_budget_usd

        if daily_total + cost > daily_limit
          raise LLM::BudgetExceededError,
            "Daily budget of $#{daily_limit} exceeded (current: $#{'%.4f' % daily_total})"
        end
      end
    end
  end
end
```

## BaseService

The base class all LLM services inherit from:

```ruby
# app/services/llm/base_service.rb
module LLM
  class BaseService
    include Concerns::Traceable
    include Concerns::Retryable
    include Concerns::CostTrackable

    class_attribute :model_name
    class_attribute :task_type  # :classification, :generation, :extraction, :reasoning

    def call(**params)
      validate_params!(params)

      with_tracing(input: params) do
        with_retries do
          model = resolve_model
          prompt = render_prompt(params)
          response = execute_llm_call(model: model, prompt: prompt)
          parsed = parse_response(response)

          cost = track_cost!(
            model: model,
            input_tokens: response.dig(:usage, :input_tokens) || 0,
            output_tokens: response.dig(:usage, :output_tokens) || 0
          )

          LLM::Result.success(parsed, model: model, trace_id: trace_id, cost_usd: cost, prompt_sha: current_prompt_sha)
        end
      end
    rescue LLM::BudgetExceededError => e
      LLM::Result.failure(e, trace_id: trace_id)
    rescue LLM::ContentFilterError => e
      LLM::Result.failure(e, trace_id: trace_id)
    rescue LLM::Error => e
      LLM::Result.failure(e, trace_id: trace_id)
    end

    private

    # Subclasses MUST implement these:

    def validate_params!(params)
      # Override to validate input
    end

    def prompt_template
      raise NotImplementedError, "#{self.class} must define #prompt_template"
    end

    def parse_response(response)
      raise NotImplementedError, "#{self.class} must define #parse_response"
    end

    # Base implementations:

    def resolve_model
      model_name || LLM::Router.resolve(task_type: self.class.task_type)
    end

    def render_prompt(params)
      LLM::PromptRenderer.render(prompt_template, **params)
    end

    def execute_llm_call(model:, prompt:)
      client = LLM::Client.for(model)  # See references/client-setup.md
      client.chat(
        model: model,
        messages: prompt,
        temperature: temperature,
        max_tokens: max_tokens
      )
    rescue Faraday::TooManyRequestsError, Net::HTTPTooManyRequests
      raise LLM::RateLimitError, "Rate limited by #{model}"
    rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout
      raise LLM::TimeoutError, "Timeout calling #{model}"
    end

    def current_prompt_sha
      path = Rails.root.join("app/prompts", "#{prompt_template}.text.erb")
      return nil unless path.exist?
      Digest::SHA256.file(path).hexdigest[0..7]
    end

    def temperature = 0.0
    def max_tokens = 1024
  end
end
```

## Example: Product Description Service

```ruby
# app/services/llm/product_description_service.rb
module LLM
  class ProductDescriptionService < BaseService
    self.task_type = :generation
    self.max_retries = 2

    private

    def validate_params!(params)
      raise ArgumentError, "product required" unless params[:product]
    end

    def prompt_template
      "product_descriptions/generate"
    end

    def parse_response(response)
      content = response.dig(:choices, 0, :message, :content)
      raise LLM::InvalidResponseError, "Empty response" if content.blank?
      {
        title: content.match(/Title: (.+)/)&.captures&.first,
        description: content.match(/Description: (.+)/m)&.captures&.first&.strip
      }
    end

    def temperature = 0.7
    def max_tokens = 512
  end
end
```

Usage:

```ruby
result = LLM::ProductDescriptionService.new.call(
  product: Product.find(42),
  tone: "professional",
  max_words: 150
)

if result.success?
  product.update!(
    ai_title: result.value[:title],
    ai_description: result.value[:description]
  )
else
  Rails.logger.error("LLM failed: #{result.error.message}")
  Sentry.capture_exception(result.error)
end
```

## Example: Ticket Triage Service

```ruby
# app/services/llm/ticket_triage_service.rb
module LLM
  class TicketTriageService < BaseService
    self.task_type = :classification  # Routes to cheap model automatically

    VALID_CATEGORIES = %w[billing technical account feature_request spam].freeze

    private

    def validate_params!(params)
      raise ArgumentError, "ticket required" unless params[:ticket]
    end

    def prompt_template
      "ticket_triage/classify"
    end

    def parse_response(response)
      content = response.dig(:choices, 0, :message, :content).to_s.strip.downcase
      category = VALID_CATEGORIES.find { |c| content.include?(c) }
      raise LLM::InvalidResponseError, "Unknown category: #{content}" unless category

      { category: category, raw_response: content }
    end

    def temperature = 0.0
    def max_tokens = 50
  end
end
```

## Pattern: Structured JSON Output

For services that need structured JSON back from the LLM:

```ruby
# app/services/llm/concerns/json_response.rb
module LLM
  module Concerns
    module JsonResponse
      private

      def parse_response(response)
        content = response.dig(:choices, 0, :message, :content)
        parsed = JSON.parse(content, symbolize_names: true)
        validate_schema!(parsed)
        parsed
      rescue JSON::ParserError => e
        raise LLM::InvalidResponseError, "Invalid JSON from LLM: #{e.message}"
      end

      def validate_schema!(parsed)
        # Override in subclass to validate expected keys
      end
    end
  end
end
```

## Pattern: Streaming Responses

For user-facing features where you need to stream tokens:

```ruby
# app/services/llm/streaming_service.rb
module LLM
  class StreamingService < BaseService
    def call_streaming(**params, &on_chunk)
      validate_params!(params)
      model = resolve_model
      prompt = render_prompt(params)
      client = LLM::Client.for(model)

      full_response = +""
      client.chat(
        model: model,
        messages: prompt,
        stream: true
      ) do |chunk|
        token = chunk.dig(:choices, 0, :delta, :content)
        next unless token

        full_response << token
        on_chunk&.call(token)
      end

      LLM::Result.success(full_response, model: model)
    end
  end
end
```

## Anti-Patterns to Avoid

1. **Direct API calls in controllers** -- Always go through a service
2. **Hardcoded prompts** -- Use `app/prompts/` templates
3. **No error handling** -- Always rescue and return Result objects
4. **Synchronous calls in request cycle** -- Use jobs unless streaming
5. **No cost tracking** -- Every call must flow through CostTrackable
6. **God services** -- One service per task, not one service for all LLM calls

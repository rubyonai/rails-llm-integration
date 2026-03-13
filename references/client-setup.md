# Client Setup

The LLM client layer that wraps provider SDKs (`ruby-openai`, `anthropic-rb`) into
a unified interface. This is the missing piece between your services and the actual
API calls.

## Gems You Need

```ruby
# Gemfile
gem "ruby-openai", "~> 7.0"    # OpenAI API client
gem "anthropic", "~> 0.3"       # Anthropic API client
gem "faraday", "~> 2.0"         # HTTP client (used by both + proxy mode)
gem "redis", "~> 5.0"           # Cost tracking, caching, rate limit state
```

Optional:

```ruby
gem "tiktoken_ruby"              # Precise token counting (instead of char estimate)
gem "braintrust", "~> 0.1"      # Eval pipeline logging
```

## Client Factory

The entry point. Every `LLM::BaseService` calls `LLM::Client.for(model)`:

```ruby
# lib/llm/client.rb
module LLM
  class Client
    # Returns a client that responds to #chat(model:, messages:, **options)
    def self.for(model)
      proxy = LLM.config.proxy_config

      if proxy["enabled"]
        ProxyClient.new(
          base_url: proxy["base_url"],
          api_key: proxy["api_key"],
          provider: proxy["provider"]
        )
      else
        provider = LLM.config.provider_for(model)
        case provider
        when "openai"
          OpenAIClient.new
        when "anthropic"
          AnthropicClient.new
        else
          raise LLM::Error, "Unknown provider '#{provider}' for model '#{model}'. " \
            "Check config/llm.yml models section."
        end
      end
    end
  end
end
```

## OpenAI Client

Wraps the `ruby-openai` gem:

```ruby
# lib/llm/clients/openai_client.rb
require "openai"

module LLM
  class OpenAIClient
    def initialize
      @client = OpenAI::Client.new(
        access_token: api_key,
        request_timeout: 120,
        log_errors: Rails.env.development?
      )
    end

    # Unified interface: returns a normalized response hash
    def chat(model:, messages:, temperature: 0.0, max_tokens: 1024, **options, &block)
      params = {
        model: model,
        messages: normalize_messages(messages),
        temperature: temperature,
        max_tokens: max_tokens
      }

      if options[:response_format] == :json
        params[:response_format] = { type: "json_object" }
      end

      if block_given?
        stream_chat(params, &block)
      else
        response = @client.chat(parameters: params)
        handle_error!(response) if response.dig("error")
        normalize_response(response)
      end
    rescue Faraday::TooManyRequestsError, OpenAI::Error => e
      raise_typed_error(e)
    rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout => e
      raise LLM::TimeoutError, "OpenAI request timed out: #{e.message}"
    end

    private

    def api_key
      LLM.config.api_key_for("openai") ||
        Rails.application.credentials.dig(:openai, :api_key) ||
        ENV["OPENAI_API_KEY"] ||
        raise(LLM::AuthenticationError, "No OpenAI API key configured. " \
          "Set it in config/llm.yml, Rails credentials, or OPENAI_API_KEY env var.")
    end

    def normalize_messages(messages)
      messages.map do |msg|
        { "role" => msg[:role].to_s, "content" => msg[:content].to_s }
      end
    end

    def normalize_response(response)
      {
        choices: response["choices"].map { |c|
          {
            message: {
              role: c.dig("message", "role"),
              content: c.dig("message", "content")
            }
          }
        },
        usage: {
          input_tokens: response.dig("usage", "prompt_tokens") || 0,
          output_tokens: response.dig("usage", "completion_tokens") || 0
        },
        model: response["model"]
      }
    end

    def stream_chat(params, &block)
      full_content = +""

      @client.chat(parameters: params.merge(stream: proc { |chunk, _bytesize|
        delta = chunk.dig("choices", 0, "delta", "content")
        if delta
          full_content << delta
          yield({
            choices: [{ delta: { content: delta } }]
          })
        end
      }))

      # Return final assembled response (no usage data in streaming)
      {
        choices: [{ message: { role: "assistant", content: full_content } }],
        usage: { input_tokens: 0, output_tokens: 0 },
        model: params[:model]
      }
    end

    def handle_error!(response)
      error = response["error"]
      message = error["message"] || error.to_s
      type = error["type"] || ""

      case type
      when "insufficient_quota"
        raise LLM::BudgetExceededError, message
      when "content_filter"
        raise LLM::ContentFilterError, message
      when "invalid_api_key", "authentication_error"
        raise LLM::AuthenticationError, message
      else
        raise LLM::Error, "OpenAI error: #{message}"
      end
    end

    def raise_typed_error(error)
      message = error.message
      case message
      when /rate limit/i, /429/
        raise LLM::RateLimitError, "OpenAI rate limited: #{message}"
      when /authentication/i, /401/
        raise LLM::AuthenticationError, "OpenAI auth failed: #{message}"
      else
        raise LLM::Error, "OpenAI error: #{message}"
      end
    end
  end
end
```

## Anthropic Client

Wraps the `anthropic-rb` gem:

```ruby
# lib/llm/clients/anthropic_client.rb
require "anthropic"

module LLM
  class AnthropicClient
    MAX_TOKENS_DEFAULT = 1024

    def initialize
      @client = Anthropic::Client.new(
        access_token: api_key
      )
    end

    # Unified interface matching OpenAIClient#chat
    def chat(model:, messages:, temperature: 0.0, max_tokens: MAX_TOKENS_DEFAULT, **options, &block)
      system_prompt, user_messages = extract_system_prompt(messages)

      params = {
        model: model,
        messages: normalize_messages(user_messages),
        max_tokens: max_tokens,
        temperature: temperature
      }
      params[:system] = system_prompt if system_prompt

      if block_given?
        stream_chat(params, &block)
      else
        response = @client.messages(parameters: params)
        handle_error!(response) if response["error"]
        normalize_response(response)
      end
    rescue Faraday::TooManyRequestsError => e
      raise LLM::RateLimitError, "Anthropic rate limited: #{e.message}"
    rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout => e
      raise LLM::TimeoutError, "Anthropic request timed out: #{e.message}"
    rescue Anthropic::Error => e
      raise_typed_error(e)
    end

    private

    def api_key
      LLM.config.api_key_for("anthropic") ||
        Rails.application.credentials.dig(:anthropic, :api_key) ||
        ENV["ANTHROPIC_API_KEY"] ||
        raise(LLM::AuthenticationError, "No Anthropic API key configured. " \
          "Set it in config/llm.yml, Rails credentials, or ANTHROPIC_API_KEY env var.")
    end

    # Anthropic uses a separate system parameter, not a system message
    def extract_system_prompt(messages)
      system_msg = messages.find { |m| m[:role].to_s == "system" }
      user_msgs = messages.reject { |m| m[:role].to_s == "system" }
      [system_msg&.dig(:content), user_msgs]
    end

    def normalize_messages(messages)
      messages.map do |msg|
        { "role" => msg[:role].to_s, "content" => msg[:content].to_s }
      end
    end

    # Normalize Anthropic response to match OpenAI format
    # This is the key adapter — all services expect the same response shape
    def normalize_response(response)
      content = response.dig("content", 0, "text") || ""

      {
        choices: [
          { message: { role: "assistant", content: content } }
        ],
        usage: {
          input_tokens: response.dig("usage", "input_tokens") || 0,
          output_tokens: response.dig("usage", "output_tokens") || 0
        },
        model: response["model"]
      }
    end

    def stream_chat(params, &block)
      full_content = +""

      @client.messages(parameters: params.merge(stream: proc { |event|
        if event["type"] == "content_block_delta"
          delta = event.dig("delta", "text")
          if delta
            full_content << delta
            yield({
              choices: [{ delta: { content: delta } }]
            })
          end
        end
      }))

      {
        choices: [{ message: { role: "assistant", content: full_content } }],
        usage: { input_tokens: 0, output_tokens: 0 },
        model: params[:model]
      }
    end

    def handle_error!(response)
      error = response["error"]
      message = error["message"] || error.to_s
      type = error["type"] || ""

      case type
      when "rate_limit_error"
        raise LLM::RateLimitError, message
      when "authentication_error"
        raise LLM::AuthenticationError, message
      when "overloaded_error"
        raise LLM::RateLimitError, "Anthropic overloaded: #{message}"
      else
        raise LLM::Error, "Anthropic error: #{message}"
      end
    end

    def raise_typed_error(error)
      message = error.message
      case message
      when /rate limit/i, /429/, /overloaded/i
        raise LLM::RateLimitError, "Anthropic: #{message}"
      when /authentication/i, /401/
        raise LLM::AuthenticationError, "Anthropic: #{message}"
      when /content/i, /safety/i
        raise LLM::ContentFilterError, "Anthropic: #{message}"
      else
        raise LLM::Error, "Anthropic: #{message}"
      end
    end
  end
end
```

## Proxy Client (LiteLLM / Portkey)

When routing through a proxy, all providers use OpenAI-compatible endpoints:

```ruby
# lib/llm/clients/proxy_client.rb
module LLM
  class ProxyClient
    def initialize(base_url:, api_key: nil, provider: "litellm")
      @provider = provider
      @connection = Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json
        f.response :raise_error
        f.options.timeout = 120
        f.options.open_timeout = 10
        f.headers["Authorization"] = "Bearer #{api_key}" if api_key
        f.adapter Faraday.default_adapter
      end
    end

    def chat(model:, messages:, temperature: 0.0, max_tokens: 1024, **options)
      body = {
        model: model,
        messages: messages.map { |m| { role: m[:role].to_s, content: m[:content].to_s } },
        temperature: temperature,
        max_tokens: max_tokens
      }

      response = @connection.post("/chat/completions") { |req| req.body = body }
      normalize_response(response.body)
    rescue Faraday::TooManyRequestsError
      raise LLM::RateLimitError, "Rate limited by #{@provider} proxy"
    rescue Faraday::TimeoutError
      raise LLM::TimeoutError, "#{@provider} proxy timed out"
    rescue Faraday::ClientError => e
      handle_proxy_error(e)
    end

    private

    def normalize_response(body)
      {
        choices: (body["choices"] || []).map { |c|
          { message: { role: c.dig("message", "role"), content: c.dig("message", "content") } }
        },
        usage: {
          input_tokens: body.dig("usage", "prompt_tokens") || 0,
          output_tokens: body.dig("usage", "completion_tokens") || 0
        },
        model: body["model"]
      }
    end

    def handle_proxy_error(error)
      status = error.response&.dig(:status)
      case status
      when 401, 403
        raise LLM::AuthenticationError, "#{@provider} proxy auth failed: #{error.message}"
      when 429
        raise LLM::RateLimitError, "#{@provider} proxy rate limited"
      else
        raise LLM::Error, "#{@provider} proxy error (#{status}): #{error.message}"
      end
    end
  end
end
```

## Config Additions

Add `provider_for` and `api_key_for` to the Config class:

```ruby
# Add these methods to lib/llm/config.rb (see proxy-routing.md for full class)

def provider_for(model_name)
  # Search all model tiers for a matching model name
  models = @config.fetch("models", {})
  models.each do |_tier, config|
    return config["provider"] if config["model"] == model_name
  end
  raise LLM::Error, "Model '#{model_name}' not found in config/llm.yml"
end

def api_key_for(provider)
  @config.dig("api_keys", provider)
end
```

## Initializer

```ruby
# config/initializers/llm.rb

# Load LLM configuration
Rails.application.config.after_initialize do
  LLM.config  # Eagerly load and validate config

  # Validate required API keys in production
  if Rails.env.production?
    %w[openai anthropic].each do |provider|
      key = LLM.config.api_key_for(provider)
      if key.blank?
        Rails.logger.warn("LLM: No API key configured for #{provider}")
      end
    end
  end
end
```

## Test Stub Client

For tests, the `stub` provider returns predictable responses:

```ruby
# lib/llm/clients/stub_client.rb
module LLM
  class StubClient
    def chat(model:, messages:, **options)
      {
        choices: [
          { message: { role: "assistant", content: "Stub response for testing" } }
        ],
        usage: { input_tokens: 10, output_tokens: 5 },
        model: model
      }
    end
  end
end
```

Add to the Client factory:

```ruby
# In LLM::Client.for, add the stub case:
when "stub"
  StubClient.new
```

## Normalized Response Shape

Every client returns this exact shape. Services depend on it:

```ruby
{
  choices: [
    { message: { role: "assistant", content: "The actual response text" } }
  ],
  usage: {
    input_tokens: 150,    # Always input_tokens, even for OpenAI (mapped from prompt_tokens)
    output_tokens: 80     # Always output_tokens (mapped from completion_tokens)
  },
  model: "gpt-4o-mini"   # Actual model used (may differ from requested in proxy mode)
}
```

This normalization is critical. OpenAI returns `prompt_tokens`/`completion_tokens`.
Anthropic returns `input_tokens`/`output_tokens` natively. The client layer maps
both to `input_tokens`/`output_tokens` so services never care about the provider.

## Directory Structure

```
lib/
  llm/
    client.rb                  # Factory: LLM::Client.for(model)
    clients/
      openai_client.rb         # Wraps ruby-openai gem
      anthropic_client.rb      # Wraps anthropic-rb gem
      proxy_client.rb          # LiteLLM/Portkey via Faraday
      stub_client.rb           # Test double
    config.rb                  # Loads config/llm.yml
    router.rb                  # Task-type routing
    cost_tracker.rb            # Redis-backed cost tracking
    ...
```

## Key Rules

1. **All clients return the same response shape** -- Services never know which provider they're talking to
2. **Error mapping happens in the client** -- Faraday errors become LLM::Error subclasses
3. **API keys resolve in order**: config/llm.yml -> Rails credentials -> ENV vars
4. **Proxy mode uses OpenAI-compatible endpoint** -- LiteLLM/Portkey both support /chat/completions
5. **System prompts are handled per-provider** -- OpenAI uses a system message, Anthropic uses a system parameter
6. **Test stub is a first-class client** -- No special-casing in services, just configure `provider: stub` in test env

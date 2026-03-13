# Client Setup

The LLM client layer that wraps provider gems into a unified interface. This skill
supports four gem choices — pick the one that fits your project, then wrap it in
the same Rails conventions.

## Choosing Your Gem

| Gem | Best For | Multi-Provider | RAG/Vectors | Complexity |
|-----|----------|----------------|-------------|------------|
| **ruby_llm** | New projects, clean DSL | Yes (OpenAI, Anthropic, Gemini, etc.) | No | Low |
| **langchain-rb** | RAG pipelines, agents, vector search | Yes | Yes (pgvector, Weaviate, Pinecone) | Medium |
| **ruby-openai** | OpenAI-only projects | No (OpenAI only) | No | Low |
| **anthropic-rb** | Anthropic-only projects | No (Anthropic only) | No | Low |

**Recommendation:** Start with `ruby_llm` for most projects. Use `langchain-rb` if you
need RAG, vector stores, or agent tooling. Use the provider-specific gems only if you're
locked to a single provider and want the thinnest wrapper.

## Gems You Need

### Option A: ruby_llm (recommended for most projects)

```ruby
# Gemfile
gem "ruby_llm", "~> 1.0"        # Multi-provider LLM client (OpenAI, Anthropic, Gemini, etc.)
gem "redis", "~> 5.0"           # Cost tracking, caching, rate limit state
```

### Option B: langchain-rb (for RAG and vector search)

```ruby
# Gemfile
gem "langchainrb", "~> 0.19"    # LLM framework with RAG, agents, vector stores
gem "pgvector", "~> 0.3"        # PostgreSQL vector extension (if using pgvector)
gem "redis", "~> 5.0"           # Cost tracking, caching, rate limit state
```

### Option C: Provider-specific gems

```ruby
# Gemfile
gem "ruby-openai", "~> 7.0"    # OpenAI API client
gem "anthropic", "~> 0.3"       # Anthropic API client
gem "faraday", "~> 2.0"         # HTTP client (used by both + proxy mode)
gem "redis", "~> 5.0"           # Cost tracking, caching, rate limit state
```

Optional (works with any option):

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
        client_mode = LLM.config.client_mode  # "ruby_llm", "langchain", or "direct"

        case client_mode
        when "ruby_llm"
          RubyLLMClient.new
        when "langchain"
          LangchainClient.new
        else
          # Direct provider-specific clients
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
end
```

## ruby_llm Client (Recommended)

Wraps the `ruby_llm` gem — the most Rubyist LLM client. Handles OpenAI, Anthropic,
Gemini, and more through a single, clean interface:

```ruby
# lib/llm/clients/ruby_llm_client.rb
require "ruby_llm"

module LLM
  class RubyLLMClient
    def initialize
      configure_ruby_llm!
    end

    # Unified interface: returns a normalized response hash
    def chat(model:, messages:, temperature: 0.0, max_tokens: 1024, **options, &block)
      chat_instance = RubyLLM.chat(model: model)
      chat_instance.with_temperature(temperature)
      chat_instance.with_max_tokens(max_tokens)

      system_prompt, user_messages = extract_system_prompt(messages)
      chat_instance.with_instructions(system_prompt) if system_prompt

      if block_given?
        stream_chat(chat_instance, user_messages, model: model, &block)
      else
        last_user_message = user_messages.last[:content].to_s
        response = chat_instance.ask(last_user_message)
        normalize_response(response, model: model)
      end
    rescue RubyLLM::RateLimitError => e
      raise LLM::RateLimitError, "Rate limited: #{e.message}"
    rescue RubyLLM::UnauthorizedError => e
      raise LLM::AuthenticationError, "Auth failed: #{e.message}"
    rescue RubyLLM::PaymentRequiredError => e
      raise LLM::BudgetExceededError, "Payment required: #{e.message}"
    rescue RubyLLM::Error => e
      raise_typed_error(e)
    rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout => e
      raise LLM::TimeoutError, "Request timed out: #{e.message}"
    end

    private

    def configure_ruby_llm!
      RubyLLM.configure do |config|
        config.openai_api_key = LLM.config.api_key_for("openai") ||
          Rails.application.credentials.dig(:openai, :api_key) ||
          ENV["OPENAI_API_KEY"]

        config.anthropic_api_key = LLM.config.api_key_for("anthropic") ||
          Rails.application.credentials.dig(:anthropic, :api_key) ||
          ENV["ANTHROPIC_API_KEY"]

        config.gemini_api_key = LLM.config.api_key_for("gemini") ||
          Rails.application.credentials.dig(:gemini, :api_key) ||
          ENV["GEMINI_API_KEY"]

        config.request_timeout = 120
      end
    end

    def extract_system_prompt(messages)
      system_msg = messages.find { |m| m[:role].to_s == "system" }
      user_msgs = messages.reject { |m| m[:role].to_s == "system" }
      [system_msg&.dig(:content), user_msgs]
    end

    def normalize_response(response, model:)
      {
        choices: [
          { message: { role: "assistant", content: response.content } }
        ],
        usage: {
          input_tokens: response.input_tokens || 0,
          output_tokens: response.output_tokens || 0
        },
        model: response.model || model
      }
    end

    def stream_chat(chat_instance, user_messages, model:, &block)
      full_content = +""
      last_user_message = user_messages.last[:content].to_s

      response = chat_instance.ask(last_user_message) do |chunk|
        if chunk.content
          full_content << chunk.content
          yield({ choices: [{ delta: { content: chunk.content } }] })
        end
      end

      {
        choices: [{ message: { role: "assistant", content: full_content } }],
        usage: {
          input_tokens: response.input_tokens || 0,
          output_tokens: response.output_tokens || 0
        },
        model: response.model || model
      }
    end

    def raise_typed_error(error)
      message = error.message
      case message
      when /rate limit/i, /429/
        raise LLM::RateLimitError, message
      when /content/i, /safety/i, /filter/i
        raise LLM::ContentFilterError, message
      else
        raise LLM::Error, "LLM error: #{message}"
      end
    end
  end
end
```

### Why ruby_llm?

```ruby
# ruby_llm is idiomatic Ruby — chainable, clean, no Python-port smell
chat = RubyLLM.chat(model: "gpt-4o-mini")
chat.ask("Classify this ticket: #{ticket.subject}")

# Multi-provider with zero config differences
chat = RubyLLM.chat(model: "claude-sonnet-4-6")
chat.ask("Same interface, different provider")

# Works naturally with ActiveRecord via acts_as_chat
class Conversation < ApplicationRecord
  acts_as_chat
end
```

## Langchain Client (For RAG Pipelines)

Wraps the `langchain-rb` gem — use this when you need RAG, vector search, agents,
or tool calling:

```ruby
# lib/llm/clients/langchain_client.rb
require "langchainrb"

module LLM
  class LangchainClient
    def initialize
      @llm_instances = {}
    end

    # Unified interface: returns a normalized response hash
    def chat(model:, messages:, temperature: 0.0, max_tokens: 1024, **options)
      llm = llm_for(model)
      prompt_text = build_prompt(messages)

      response = llm.chat(messages: format_messages(messages))
      normalize_response(response, model: model)
    rescue Langchain::LLM::ApiError => e
      raise_typed_error(e)
    rescue Faraday::TooManyRequestsError => e
      raise LLM::RateLimitError, "Rate limited: #{e.message}"
    rescue Faraday::TimeoutError, Net::OpenTimeout, Net::ReadTimeout => e
      raise LLM::TimeoutError, "Request timed out: #{e.message}"
    end

    # RAG-specific methods — the reason you'd choose langchain-rb

    def embed(text:, model: "text-embedding-3-small")
      llm = llm_for(model)
      llm.embed(text: text).embedding
    end

    def similarity_search(query:, collection:, k: 5)
      collection.similarity_search(query: query, k: k)
    end

    private

    def llm_for(model)
      provider = LLM.config.provider_for(model)

      @llm_instances[provider] ||= case provider
      when "openai"
        Langchain::LLM::OpenAI.new(
          api_key: resolve_key("openai"),
          default_options: { chat_model: model }
        )
      when "anthropic"
        Langchain::LLM::Anthropic.new(
          api_key: resolve_key("anthropic"),
          default_options: { chat_model: model }
        )
      when "google", "gemini"
        Langchain::LLM::GoogleGemini.new(
          api_key: resolve_key("gemini"),
          default_options: { chat_model: model }
        )
      else
        raise LLM::Error, "langchain-rb does not support provider '#{provider}'"
      end
    end

    def resolve_key(provider)
      LLM.config.api_key_for(provider) ||
        Rails.application.credentials.dig(provider.to_sym, :api_key) ||
        ENV["#{provider.upcase}_API_KEY"] ||
        raise(LLM::AuthenticationError, "No #{provider} API key configured.")
    end

    def format_messages(messages)
      messages.map do |msg|
        { role: msg[:role].to_s, content: msg[:content].to_s }
      end
    end

    def normalize_response(response, model:)
      {
        choices: [
          { message: { role: "assistant", content: response.chat_completion } }
        ],
        usage: {
          input_tokens: response.prompt_tokens || 0,
          output_tokens: response.completion_tokens || 0
        },
        model: model
      }
    end

    def build_prompt(messages)
      messages.map { |m| m[:content].to_s }.join("\n\n")
    end

    def raise_typed_error(error)
      message = error.message
      case message
      when /rate limit/i, /429/
        raise LLM::RateLimitError, message
      when /authentication/i, /401/, /unauthorized/i
        raise LLM::AuthenticationError, message
      when /content/i, /safety/i, /filter/i
        raise LLM::ContentFilterError, message
      else
        raise LLM::Error, "Langchain error: #{message}"
      end
    end
  end
end
```

### When to use langchain-rb

```ruby
# RAG pipeline with pgvector — langchain-rb's killer feature
vectorsearch = Langchain::Vectorsearch::Pgvector.new(
  url: ENV["DATABASE_URL"],
  index_name: "documents",
  llm: Langchain::LLM::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])
)

# Add documents
vectorsearch.add_texts(texts: Document.pluck(:content))

# Search with semantic similarity
results = vectorsearch.similarity_search(query: "billing issues", k: 5)

# RAG: search + generate in one step
answer = vectorsearch.ask(question: "How do I reset my password?")
```

### Using langchain-rb with BaseService for RAG

```ruby
# app/services/llm/rag_answer_service.rb
module LLM
  class RagAnswerService < BaseService
    self.task_type = :reasoning

    private

    def validate_params!(params)
      raise ArgumentError, "question required" unless params[:question]
      raise ArgumentError, "collection required" unless params[:collection]
    end

    def prompt_template
      "rag/answer"
    end

    # Override execute_llm_call to include RAG context
    def execute_llm_call(model:, prompt:)
      client = LLM::Client.for(model)

      # Retrieve relevant context via vector search
      context_docs = client.similarity_search(
        query: @params[:question],
        collection: @params[:collection],
        k: 5
      )

      # Inject context into the prompt
      augmented_messages = prompt.map do |msg|
        if msg[:role] == "user"
          { role: "user", content: "Context:\n#{context_docs.join("\n")}\n\nQuestion: #{msg[:content]}" }
        else
          msg
        end
      end

      client.chat(model: model, messages: augmented_messages)
    end

    def parse_response(response)
      content = response.dig(:choices, 0, :message, :content)
      { answer: content.strip }
    end
  end
end
```

## OpenAI Client (Direct)

Wraps the `ruby-openai` gem — use when you only need OpenAI and want the thinnest wrapper:

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

Add `client_mode`, `provider_for` and `api_key_for` to the Config class:

```ruby
# Add these methods to lib/llm/config.rb (see proxy-routing.md for full class)

# Which client gem to use: "ruby_llm" (default), "langchain", or "direct"
def client_mode
  @config.fetch("client_mode", "ruby_llm")
end

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
      ruby_llm_client.rb      # Wraps ruby_llm gem (recommended)
      langchain_client.rb     # Wraps langchain-rb gem (for RAG)
      openai_client.rb         # Wraps ruby-openai gem (direct)
      anthropic_client.rb      # Wraps anthropic-rb gem (direct)
      proxy_client.rb          # LiteLLM/Portkey via Faraday
      stub_client.rb           # Test double
    config.rb                  # Loads config/llm.yml
    router.rb                  # Task-type routing
    cost_tracker.rb            # Redis-backed cost tracking
    ...
```

## Key Rules

1. **All clients return the same response shape** -- ruby_llm, langchain-rb, ruby-openai, anthropic-rb — all normalize to `{choices, usage, model}`
2. **Choose your gem, keep the convention** -- The Rails patterns (BaseService, BaseJob, Router) work identically regardless of which client gem you use
3. **ruby_llm for most projects** -- Clean DSL, multi-provider, works with ActiveRecord via `acts_as_chat`. Start here unless you need RAG
4. **langchain-rb for RAG** -- If you need vector search, pgvector, embeddings, or agents, langchain-rb is the right choice
5. **Error mapping happens in the client** -- Provider-specific errors become LLM::Error subclasses. Services never rescue Faraday errors directly
6. **API keys resolve in order**: config/llm.yml -> Rails credentials -> ENV vars
7. **Proxy mode uses OpenAI-compatible endpoint** -- LiteLLM/Portkey both support /chat/completions
8. **Test stub is a first-class client** -- No special-casing in services, just configure `provider: stub` in test env
9. **Set `client_mode` in config/llm.yml** -- `ruby_llm` (default), `langchain`, or `direct` (provider-specific gems)

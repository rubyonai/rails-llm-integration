# Testing Guide

One clear testing strategy for LLM-integrated Rails apps. No ambiguity.

## Testing Pyramid for LLM Features

```
    /  Eval Regression  \       ← Nightly CI, real API calls
   /  Integration (VCR)  \      ← Record once, replay in CI
  /   Unit Tests (Stubs)   \    ← Every CI run, fast, deterministic
```

## Level 1: Unit Tests with Stubs

Stub the HTTP layer. Test your service logic, not the LLM API.

### WebMock Setup

```ruby
# spec/support/llm_stubs.rb
module LLMStubs
  def stub_llm_response(model:, content:, input_tokens: 100, output_tokens: 50)
    stub_request(:post, /chat\/completions/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [{ message: { role: "assistant", content: content } }],
          usage: { input_tokens: input_tokens, output_tokens: output_tokens },
          model: model
        }.to_json
      )
  end

  def stub_llm_rate_limit
    stub_request(:post, /chat\/completions/)
      .to_return(status: 429, body: { error: { message: "Rate limited" } }.to_json)
  end

  def stub_llm_timeout
    stub_request(:post, /chat\/completions/).to_timeout
  end

  def stub_llm_content_filter
    stub_request(:post, /chat\/completions/)
      .to_return(
        status: 400,
        body: { error: { message: "Content filtered", type: "content_filter" } }.to_json
      )
  end
end

RSpec.configure do |config|
  config.include LLMStubs
end
```

### Stubbing ruby_llm Directly

If you're using `ruby_llm` and want to stub at the gem level instead of HTTP:

```ruby
# spec/support/ruby_llm_stubs.rb
module RubyLLMStubs
  def stub_ruby_llm_chat(content:, model: "gpt-4o-mini", input_tokens: 100, output_tokens: 50)
    response = instance_double(RubyLLM::Response,
      content: content,
      model: model,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
    chat_instance = instance_double(RubyLLM::Chat)
    allow(chat_instance).to receive(:with_temperature).and_return(chat_instance)
    allow(chat_instance).to receive(:with_max_tokens).and_return(chat_instance)
    allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).and_return(response)
    allow(RubyLLM).to receive(:chat).and_return(chat_instance)
  end
end

RSpec.configure do |config|
  config.include RubyLLMStubs
end
```

### Stubbing langchain-rb Directly

```ruby
# spec/support/langchain_stubs.rb
module LangchainStubs
  def stub_langchain_chat(content:, model: "gpt-4o-mini", input_tokens: 100, output_tokens: 50)
    response = instance_double(Langchain::LLM::OpenAIResponse,
      chat_completion: content,
      prompt_tokens: input_tokens,
      completion_tokens: output_tokens
    )
    llm = instance_double(Langchain::LLM::OpenAI)
    allow(llm).to receive(:chat).and_return(response)
    allow(Langchain::LLM::OpenAI).to receive(:new).and_return(llm)
  end

  def stub_langchain_embedding(embedding: Array.new(1536) { rand })
    response = instance_double(Langchain::LLM::OpenAIResponse,
      embedding: embedding
    )
    llm = instance_double(Langchain::LLM::OpenAI)
    allow(llm).to receive(:embed).and_return(response)
    allow(Langchain::LLM::OpenAI).to receive(:new).and_return(llm)
  end
end

RSpec.configure do |config|
  config.include LangchainStubs
end
```

### Testing a Service

```ruby
# spec/services/llm/product_description_service_spec.rb
RSpec.describe LLM::ProductDescriptionService do
  let(:product) { create(:product, name: "Widget", category: "Tools") }

  describe "#call" do
    it "returns a successful result with parsed output" do
      stub_llm_response(
        model: "gpt-4o-mini",
        content: "Title: Amazing Widget\nDescription: A great tool for every workshop."
      )

      result = described_class.new.call(product: product)

      expect(result).to be_success
      expect(result.value[:title]).to eq("Amazing Widget")
      expect(result.value[:description]).to eq("A great tool for every workshop.")
    end

    it "returns failure on empty response" do
      stub_llm_response(model: "gpt-4o-mini", content: "")

      result = described_class.new.call(product: product)

      expect(result).to be_failure
      expect(result.error).to be_a(LLM::InvalidResponseError)
    end

    it "returns failure on rate limit" do
      stub_llm_rate_limit

      result = described_class.new.call(product: product)

      expect(result).to be_failure
      expect(result.error).to be_a(LLM::RateLimitError)
    end

    it "requires a product" do
      expect { described_class.new.call }.to raise_error(ArgumentError)
    end
  end
end
```

### Response Fixture Factory

```ruby
# spec/factories/llm_responses.rb
module LLMResponseFactory
  def self.product_description(title: "Great Product", description: "A fine item.")
    {
      choices: [{
        message: {
          role: "assistant",
          content: "Title: #{title}\nDescription: #{description}"
        }
      }],
      usage: { input_tokens: 150, output_tokens: 80 },
      model: "gpt-4o-mini"
    }
  end

  def self.classification(category: "billing")
    {
      choices: [{
        message: { role: "assistant", content: category }
      }],
      usage: { input_tokens: 200, output_tokens: 5 },
      model: "gpt-4o-mini"
    }
  end

  def self.json_response(data)
    {
      choices: [{
        message: { role: "assistant", content: data.to_json }
      }],
      usage: { input_tokens: 100, output_tokens: 50 },
      model: "gpt-4o-mini"
    }
  end

  def self.error_response(status:, message:, type: "api_error")
    {
      status: status,
      body: { error: { message: message, type: type } }.to_json
    }
  end
end
```

## Level 2: Integration Tests with VCR

Record real API responses once, replay them forever.

### VCR Setup

```ruby
# spec/support/vcr.rb
require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/cassettes/llm"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # Filter sensitive data
  config.filter_sensitive_data("<OPENAI_API_KEY>") { ENV["OPENAI_API_KEY"] }
  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") { ENV["ANTHROPIC_API_KEY"] }

  # Match on method + path, ignore headers (API keys change)
  config.default_cassette_options = {
    match_requests_on: [:method, :uri, :body],
    record: :once
  }
end
```

### VCR Integration Test

```ruby
# spec/integration/llm/product_description_spec.rb
RSpec.describe "Product description generation", :vcr do
  it "generates a description from real API" do
    product = create(:product, name: "Ergonomic Keyboard", category: "Electronics")

    result = LLM::ProductDescriptionService.new.call(
      product: product,
      tone: "professional"
    )

    expect(result).to be_success
    expect(result.value[:title]).to be_present
    expect(result.value[:description].length).to be > 20
  end
end
```

To re-record: delete the cassette file and run the test with real API keys.

## Level 3: Shared Examples

Reusable test patterns for all LLM services:

```ruby
# spec/support/shared_examples/llm_service.rb
RSpec.shared_examples "an LLM service" do |service_class|
  describe "common LLM service behavior" do
    it "returns an LLM::Result" do
      stub_llm_response(model: "gpt-4o-mini", content: valid_response_content)
      result = service_class.new.call(**valid_params)
      expect(result).to be_a(LLM::Result)
    end

    it "handles rate limits gracefully" do
      stub_llm_rate_limit
      result = service_class.new.call(**valid_params)
      expect(result).to be_failure
    end

    it "handles timeouts gracefully" do
      stub_llm_timeout
      result = service_class.new.call(**valid_params)
      expect(result).to be_failure
    end

    it "includes trace_id in metadata" do
      stub_llm_response(model: "gpt-4o-mini", content: valid_response_content)
      result = service_class.new.call(**valid_params)
      expect(result.metadata[:trace_id]).to be_present
    end

    it "includes model in metadata" do
      stub_llm_response(model: "gpt-4o-mini", content: valid_response_content)
      result = service_class.new.call(**valid_params)
      expect(result.metadata[:model]).to be_present
    end
  end
end

# Usage in a service spec:
RSpec.describe LLM::ProductDescriptionService do
  it_behaves_like "an LLM service", described_class do
    let(:valid_params) { { product: create(:product) } }
    let(:valid_response_content) { "Title: Test\nDescription: A test product." }
  end
end
```

## Level 4: Prompt Rendering Tests

Test the prompt template independently:

```ruby
# spec/prompts/product_descriptions_spec.rb
RSpec.describe "product_descriptions prompts" do
  let(:product) { build(:product, name: "Widget", price: 29.99, features: ["durable", "lightweight"]) }

  describe "generate.text.erb" do
    it "includes product details" do
      text = LLM::PromptRenderer.render_text(
        "product_descriptions/generate",
        product: product,
        tone: "casual",
        max_words: 100
      )

      expect(text).to include("Widget")
      expect(text).to include("29.99")
      expect(text).to include("durable")
      expect(text).to include("casual")
    end

    it "omits optional sections when not provided" do
      text = LLM::PromptRenderer.render_text(
        "product_descriptions/generate",
        product: product
      )

      expect(text).not_to include("Tone:")
    end
  end

  describe "generate.system.erb" do
    it "renders system prompt" do
      messages = LLM::PromptRenderer.render(
        "product_descriptions/generate",
        product: product
      )

      system_msg = messages.find { |m| m[:role] == "system" }
      expect(system_msg[:content]).to include("product copywriter")
    end
  end
end
```

## Level 5: Quality Threshold Tests

Assert output quality without calling the API (use saved fixtures):

```ruby
# spec/quality/product_description_quality_spec.rb
RSpec.describe "Product description quality" do
  # These use pre-recorded responses to check parsing and quality
  let(:fixtures) { YAML.load_file("spec/fixtures/llm/product_descriptions.yml") }

  fixtures.each do |fixture|
    it "parses fixture: #{fixture['name']}" do
      stub_llm_response(model: "gpt-4o-mini", content: fixture["response"])

      result = LLM::ProductDescriptionService.new.call(
        product: build(:product, **fixture["input"].symbolize_keys)
      )

      expect(result).to be_success
      expect(result.value[:title]).to be_present
      expect(result.value[:description].split.size).to be >= 10
      expect(result.value[:description]).not_to include("As an AI")
    end
  end
end
```

Fixture file:

```yaml
# spec/fixtures/llm/product_descriptions.yml
- name: "standard product"
  input:
    name: "Wireless Mouse"
    category: "Electronics"
  response: |
    Title: Premium Wireless Mouse
    Description: Navigate with precision using this ergonomic wireless mouse.
      Features a responsive optical sensor and long-lasting battery life.

- name: "edge case - long name"
  input:
    name: "Super Ultra Premium Deluxe Wireless Ergonomic Gaming Mouse Pro Edition"
    category: "Gaming"
  response: |
    Title: Ultra Gaming Mouse Pro
    Description: Dominate your games with this professional-grade wireless mouse.
```

## CI Strategy

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
      - run: bundle exec rspec --exclude-pattern "spec/eval/**/*_spec.rb"
        # No API keys needed -- everything is stubbed

  # Nightly: real API calls against eval dataset
  eval-regression:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
      - run: bundle exec rspec spec/eval/ --tag eval
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          BRAINTRUST_API_KEY: ${{ secrets.BRAINTRUST_API_KEY }}
```

## Key Rules

1. **Unit tests use WebMock stubs** -- fast, deterministic, no API keys
2. **Integration tests use VCR** -- record once, replay forever
3. **Shared examples enforce consistency** -- every service gets the same checks
4. **Test prompt rendering separately** -- catch template bugs without API calls
5. **Quality fixtures catch regressions** -- saved responses validate parsing
6. **Real API calls only in nightly CI** -- never block a PR on LLM latency
7. **Filter API keys in VCR cassettes** -- never commit secrets

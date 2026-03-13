# Prompt Management

Prompts as views. Just like Rails renders HTML views with ERB, your LLM prompts live in
`app/prompts/` as ERB templates, rendered with locals, versioned in git.

## Directory Structure

Mirrors `app/views/`:

```
app/
  prompts/
    product_descriptions/
      generate.text.erb          # Main generation prompt
      _examples.text.erb         # Few-shot examples partial
    ticket_triage/
      classify.text.erb
      classify.system.erb        # System prompt (separate file)
    summarization/
      summarize.text.erb
      summarize.system.erb
    shared/
      _json_format.text.erb      # Shared partial for JSON output instructions
      _tone_guide.text.erb       # Shared tone instructions
```

Naming convention:
- `{action}.text.erb` -- User prompt
- `{action}.system.erb` -- System prompt (optional)
- `_{name}.text.erb` -- Partial (reusable fragments)

## Prompt Renderer

```ruby
# lib/llm/prompt_renderer.rb
module LLM
  class PromptRenderer
    PROMPTS_DIR = "app/prompts"

    # Render a prompt template and return messages array
    def self.render(template_name, **locals)
      messages = []

      # Render system prompt if it exists
      system_path = template_path(template_name, type: "system")
      if system_path
        messages << {
          role: "system",
          content: render_template(system_path, **locals)
        }
      end

      # Render user prompt
      user_path = template_path(template_name, type: "text")
      raise "Prompt template not found: #{template_name}" unless user_path

      messages << {
        role: "user",
        content: render_template(user_path, **locals)
      }

      messages
    end

    # Render just the text content (for testing)
    def self.render_text(template_name, **locals)
      path = template_path(template_name, type: "text")
      raise "Prompt template not found: #{template_name}" unless path
      render_template(path, **locals)
    end

    private_class_method def self.template_path(name, type:)
      path = Rails.root.join(PROMPTS_DIR, "#{name}.#{type}.erb")
      path.exist? ? path : nil
    end

    private_class_method def self.render_template(path, **locals)
      template = File.read(path)
      context = RenderContext.new(**locals)
      ERB.new(template, trim_mode: "-").result(context.get_binding)
    end
  end

  class RenderContext
    def initialize(**locals)
      locals.each do |key, value|
        instance_variable_set(:"@#{key}", value)
        self.class.attr_reader(key) unless respond_to?(key)
      end
    end

    def get_binding
      binding
    end

    # Render a partial
    def render_partial(name, **partial_locals)
      merged = instance_variables.each_with_object({}) { |iv, h|
        key = iv.to_s.delete("@").to_sym
        h[key] = instance_variable_get(iv)
      }.merge(partial_locals)

      LLM::PromptRenderer.render_text(name, **merged)
    end
  end
end
```

## Example Prompt Templates

### System Prompt

```erb
<%# app/prompts/product_descriptions/generate.system.erb %>
You are an expert product copywriter for an e-commerce platform.
You write compelling, accurate product descriptions that drive conversions.

Rules:
- Be factual. Never invent features the product doesn't have.
- Match the requested tone exactly.
- Stay within the word limit.
- Return your response in the exact format specified.
```

### User Prompt with Locals

```erb
<%# app/prompts/product_descriptions/generate.text.erb %>
Write a product description for the following item:

Product: <%= @product.name %>
Category: <%= @product.category %>
Price: $<%= @product.price %>
Features:
<% @product.features.each do |feature| -%>
- <%= feature %>
<% end -%>

<% if @tone -%>
Tone: <%= @tone %>
<% end -%>

<% if @max_words -%>
Maximum length: <%= @max_words %> words
<% end -%>

Return your response in this exact format:
Title: [catchy product title]
Description: [the product description]
```

### Few-Shot Examples Partial

```erb
<%# app/prompts/product_descriptions/_examples.text.erb %>
Here are examples of good product descriptions:

<% @examples.each do |example| -%>
---
Product: <%= example[:product_name] %>
Title: <%= example[:title] %>
Description: <%= example[:description] %>
<% end -%>
---

Now write one for the following product:
```

### Using Partials in a Prompt

```erb
<%# app/prompts/ticket_triage/classify.text.erb %>
Classify the following support ticket into exactly one category.

Valid categories: billing, technical, account, feature_request, spam

<%= render_partial("shared/_json_format", format: "category") %>

Ticket subject: <%= @ticket.subject %>
Ticket body:
<%= @ticket.body %>
```

### Shared JSON Format Partial

```erb
<%# app/prompts/shared/_json_format.text.erb %>
Return your response as valid JSON with the following structure:
{
  "<%= @format %>": "your answer here"
}

Return ONLY the JSON object, no additional text.
```

## Prompt Versioning Strategy

Prompts are versioned in git. No separate database needed.

```ruby
# Track which prompt version generated each output
# Store the git SHA alongside the LLM output

class Product < ApplicationRecord
  def ai_prompt_version
    # Stored when description was generated
    ai_metadata&.dig("prompt_sha")
  end
end

# In your service:
def call(**params)
  result = super
  if result.success?
    result.metadata[:prompt_sha] = current_prompt_sha
  end
  result
end

def current_prompt_sha
  path = Rails.root.join("app/prompts", "#{prompt_template}.text.erb")
  Digest::SHA256.file(path).hexdigest[0..7]
end
```

When you change a prompt, the SHA changes. You can:
- Track which version generated each output
- Compare output quality across prompt versions
- Roll back by reverting the git commit

## Locale-Aware Prompts

For multilingual Rails apps, follow the I18n pattern:

```
app/
  prompts/
    product_descriptions/
      generate.text.erb          # Default (English)
      generate.text.es.erb       # Spanish
      generate.text.fr.erb       # French
      generate.system.erb        # System prompt (usually English)
```

```ruby
# In PromptRenderer, add locale support:
private_class_method def self.template_path(name, type:)
  locale = I18n.locale

  # Try locale-specific first
  localized = Rails.root.join(PROMPTS_DIR, "#{name}.#{type}.#{locale}.erb")
  return localized if localized.exist?

  # Fall back to default
  default = Rails.root.join(PROMPTS_DIR, "#{name}.#{type}.erb")
  default.exist? ? default : nil
end
```

## Testing Prompts

Test the rendered prompt string independently from the API call:

```ruby
# spec/prompts/product_descriptions/generate_spec.rb
RSpec.describe "product_descriptions/generate prompt" do
  let(:product) { build(:product, name: "Widget", category: "Tools", price: 29.99) }

  it "renders with required locals" do
    text = LLM::PromptRenderer.render_text(
      "product_descriptions/generate",
      product: product,
      tone: "professional",
      max_words: 100
    )

    expect(text).to include("Widget")
    expect(text).to include("Tools")
    expect(text).to include("$29.99")
    expect(text).to include("professional")
    expect(text).to include("100 words")
  end

  it "renders valid messages array" do
    messages = LLM::PromptRenderer.render(
      "product_descriptions/generate",
      product: product
    )

    expect(messages).to be_an(Array)
    expect(messages.first[:role]).to eq("system")
    expect(messages.last[:role]).to eq("user")
  end

  it "handles missing optional locals gracefully" do
    text = LLM::PromptRenderer.render_text(
      "product_descriptions/generate",
      product: product
    )

    expect(text).not_to include("Tone:")
    expect(text).not_to include("Maximum length:")
  end
end
```

## Key Rules

1. **Never hardcode prompts as strings** -- always use `app/prompts/` templates
2. **System prompts are separate files** -- `.system.erb` next to `.text.erb`
3. **Partials start with underscore** -- just like Rails views
4. **Version prompts in git** -- track SHA per output for traceability
5. **Test prompt rendering** -- unit test the string before it hits the API
6. **Locale follows I18n** -- `generate.text.es.erb` for Spanish

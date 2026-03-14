<p align="center">
  <h1 align="center">Rails LLM Integration</h1>
  <p align="center">
    <strong>The missing Rails convention for LLM calls.</strong>
  </p>
  <p align="center">
    A Claude Skill that teaches Claude Code how to write LLM features<br/>
    using the patterns Rails devs already know.
  </p>
</p>

<p align="center">
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Ruby-3.2%2B-CC342D?logo=ruby" alt="Ruby"></a>
  <a href="https://rubyonrails.org/"><img src="https://img.shields.io/badge/Rails-7.1%2B-D30001?logo=rubyonrails" alt="Rails"></a>
  <a href="https://docs.anthropic.com/en/docs/claude-code/skills"><img src="https://img.shields.io/badge/Claude_Code-Skill-7C3AED" alt="Claude Skill"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
</p>

<p align="center">
  Works with <strong>ruby_llm</strong> · <strong>langchain-rb</strong> · <strong>ruby-openai</strong> · <strong>anthropic-rb</strong>
</p>

---

## Why This Exists

Rails has conventions for email, jobs, storage, and config. But not for LLM calls. So every team ends up with something like this:

```ruby
# Raw API call in a controller. No retries, no cost tracking, blocks the request.
def create
  client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
  response = client.chat(parameters: {
    model: "gpt-4o",
    messages: [{ role: "user", content: "Describe #{@product.name}" }]
  })
  @product.update!(description: response.dig("choices", 0, "message", "content"))
end
```

It works, but it doesn't scale. There's no retry when you get rate limited, no way to know what you're spending, prompts are strings scattered across files, and every developer does it differently.

This skill gives Claude Code a set of Rails conventions for LLM calls. Install it once, and Claude starts using them whenever you ask it to build AI features.

## What It Looks Like

```ruby
# One line. Runs async, retries on failure, tracks cost, logs to Braintrust.
LLM::GenerateDescriptionJob.perform_later(product_id: @product.id)
```

Behind that one line:

```
app/
  services/llm/
    product_description_service.rb    # Business logic, validation, parsing
    base_service.rb                   # Tracing, retries, cost tracking (inherited)
  jobs/llm/
    generate_description_job.rb       # Async with typed retry rules
  prompts/
    product_descriptions/
      generate.system.erb             # Versioned in git, tested on its own
      generate.text.erb
config/
  llm.yml                            # Model routing + budget caps (like database.yml)
```

Same structure for every LLM feature. A new developer joining the team knows where things go on day one.

## How It Works

This is a [Claude Skill](https://docs.anthropic.com/en/docs/claude-code/skills). It's a set of reference docs that Claude Code reads before answering your prompts. It doesn't change your app. It changes how Claude helps you build your app.

```
You: "Add ticket classification to my app"

Without skill: Claude writes a raw API call in your controller
With skill:    Claude writes a BaseService subclass, async job, prompt template, and test
```

### Installation

```bash
# Copy into your Rails project's skills directory
cp -r rails-llm-integration/ your-rails-app/.claude/skills/rails-llm-integration/
```

Next time you ask Claude Code about LLM features, it picks up these conventions automatically.

## The 6 Patterns

<table>
<tr>
<td width="50%">

### 1. Service Objects

Every LLM call goes through a service. Validation, prompt rendering, response parsing, all in one place.

```ruby
class LLM::TicketTriageService < LLM::BaseService
  self.task_type = :classification

  def prompt_template
    "ticket_triage/classify"
  end

  def parse_response(response)
    # your parsing logic
  end
end
```

</td>
<td width="50%">

### 2. Async Jobs

LLM calls are slow. Don't block web requests. Three queue tiers with typed retry rules.

```ruby
# Rate limits: retry with backoff
# Timeouts: retry 3x
# Content filter: discard and alert
# Budget exceeded: discard and alert

LLM::TriageTicketJob.perform_later(ticket_id: 42)
```

</td>
</tr>
<tr>
<td>

### 3. Model Routing

Simple tasks use cheap models. Complex tasks use expensive ones. Set a daily budget so you don't get surprised.

```yaml
# config/llm.yml
routing:
  classification: cheap      # GPT-4o-mini
  generation: standard       # Claude Sonnet
  reasoning: expensive       # Claude Opus

daily_budget_usd: 500.00
```

</td>
<td>

### 4. Eval Pipeline

Log every call to Braintrust. Build eval datasets from real production data. Score quality automatically. Fail CI if quality drops.

```ruby
# Maturity ladder:
# Week 1:  Trace logging (automatic)
# Week 3:  Dataset curation
# Week 6:  LLM-as-judge scoring
# Week 8+: CI regression gates
```

</td>
</tr>
<tr>
<td>

### 5. Prompts as Views

Prompts live in `app/prompts/` as ERB templates. Version them in git. Test them on their own. Support multiple languages with i18n.

```
app/prompts/
  product_descriptions/
    generate.system.erb
    generate.text.erb
  shared/
    _json_format.text.erb
```

</td>
<td>

### 6. Testing

Stub LLM responses in unit tests. Record real responses with VCR. Share examples across services. No API keys needed in CI.

```ruby
it "classifies the ticket" do
  stub_llm_response(
    model: "gpt-4o-mini",
    content: "billing"
  )
  result = service.call(ticket: ticket)
  expect(result.value[:category]).to eq("billing")
end
```

</td>
</tr>
</table>

## Quick Start

Once the skill is installed, Claude Code uses these conventions when setting up your app:

**1. Pick your gem**

```ruby
# Gemfile

gem "ruby_llm", "~> 1.0"         # Recommended: multi-provider, clean Ruby DSL
gem "langchainrb", "~> 0.19"     # For RAG, vector search, agents
gem "ruby-openai", "~> 7.0"      # OpenAI only
gem "anthropic", "~> 0.3"        # Anthropic only
```

**2. Generate the stack**

```bash
rails generate llm:install
rails db:migrate
```

**3. Add API keys**

```bash
rails credentials:edit
# openai:
#   api_key: sk-...
# anthropic:
#   api_key: sk-ant-...
```

**4. Create your first service**

```bash
rails generate llm:service ProductDescription generation
```

**5. Audit existing code**

```bash
ruby scripts/audit_llm_usage.rb /path/to/your/app
```

The audit script looks for raw API calls, hardcoded prompts, missing cost tracking, and sync LLM calls in controllers. It tells you what to fix and where.

## What's Inside

| Reference | What It Covers |
|-----------|---------------|
| [client-setup.md](references/client-setup.md) | ruby_llm, langchain-rb, ruby-openai, anthropic-rb wrappers. All return the same normalized response shape |
| [service-patterns.md](references/service-patterns.md) | BaseService, Result pattern, Traceable / Retryable / CostTrackable concerns, error types |
| [job-patterns.md](references/job-patterns.md) | Three-queue Sidekiq strategy, typed retry rules, batch processing, dead letter handling |
| [proxy-routing.md](references/proxy-routing.md) | config/llm.yml, model routing, shadow experiments, LiteLLM / Portkey, budget guardrails |
| [eval-pipeline.md](references/eval-pipeline.md) | Braintrust logging, LLM-as-judge, eval datasets from production, CI gates |
| [prompt-management.md](references/prompt-management.md) | ERB templates in app/prompts/, partials, i18n, prompt versioning via git SHA |
| [testing-guide.md](references/testing-guide.md) | WebMock stubs, VCR cassettes, shared RSpec examples, CI strategy |
| [generators.md](references/generators.md) | `llm:install` and `llm:service` Rails generators |

Also includes 3 generator templates, 4 migration templates, and a codebase audit script.

## Who This Is For

Rails developers adding LLM features to production apps. If you know ActionMailer and ActiveJob, you already know the patterns. This skill teaches Claude to use them for LLM calls.

## Compatible With

| | Gem | Use Case |
|-|-----|----------|
| Recommended | [ruby_llm](https://github.com/crmne/ruby_llm) | Multi-provider, clean DSL, ActiveRecord integration |
| For RAG | [langchain-rb](https://github.com/patterns-ai-core/langchainrb) | Vector search, pgvector, embeddings, agents |
| Direct | [ruby-openai](https://github.com/alexrudall/ruby-openai) | OpenAI-only projects |
| Direct | [anthropic-rb](https://github.com/alexrudall/anthropic) | Anthropic-only projects |
| Proxy | [LiteLLM](https://github.com/BerriAI/litellm) / [Portkey](https://portkey.ai) | Multi-provider routing, cost tracking |
| Evals | [Braintrust](https://braintrust.dev) | Trace logging, quality scoring, CI gates |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Every pattern should come from real production use. Code blocks should be copy-pasteable into a Rails app.

## License

[MIT](LICENSE) - Ruby on AI

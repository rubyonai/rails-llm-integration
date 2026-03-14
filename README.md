<p align="center">
  <h1 align="center">Rails LLM Integration</h1>
  <p align="center">
    <strong>The missing Rails convention for LLM calls.</strong>
  </p>
  <p align="center">
    A Claude Skill that makes Claude Code write production-grade LLM features<br/>
    using the same patterns Rails devs already know.
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

Rails has conventions for everything — email, jobs, storage, config. But when it comes to LLM calls? Nothing. Every team reinvents the wheel:

```ruby
# This is what most Rails + LLM code looks like today
def create
  client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
  response = client.chat(parameters: {
    model: "gpt-4o",
    messages: [{ role: "user", content: "Describe #{@product.name}" }]
  })
  @product.update!(description: response.dig("choices", 0, "message", "content"))
end
```

No retries. No cost tracking. No fallback. Blocking your Puma threads for 3 seconds. Prompts hardcoded as strings. API bill climbing with zero visibility. And every developer on the team writes it differently.

**This skill fixes that.** Install it once, and Claude Code responds with Rails conventions instead of raw API calls — every time.

## What It Looks Like

```ruby
# After: one line to kick off an LLM call
LLM::GenerateDescriptionJob.perform_later(product_id: @product.id)
```

Behind that one line, you get:

```
app/
  services/llm/
    product_description_service.rb    # Business logic, validation, parsing
    base_service.rb                   # Tracing, retries, cost tracking — inherited
  jobs/llm/
    generate_description_job.rb       # Async by default, typed retry rules
  prompts/
    product_descriptions/
      generate.system.erb             # Versioned in git, tested independently
      generate.text.erb
config/
  llm.yml                            # Model routing + budget caps (like database.yml)
```

Every LLM feature follows the same structure. New developer joins? They already know where everything goes.

## How It Works

This is a [Claude Skill](https://docs.anthropic.com/en/docs/claude-code/skills) — a set of reference docs that Claude Code reads before responding to your prompts. It doesn't change your app. It changes how Claude helps you build your app.

```
You: "Add AI-powered ticket classification to my app"

Without skill → Claude writes raw API calls in your controller
With skill    → Claude writes BaseService subclass + async job + prompt template + test
```

### Install in 10 seconds

```bash
# Clone into your Rails project's skills directory
cp -r rails-llm-integration/ your-rails-app/.claude/skills/rails-llm-integration/
```

That's it. Next time you ask Claude Code anything about LLM features, it uses these conventions automatically.

## The 6 Patterns

<table>
<tr>
<td width="50%">

### 1. Service Objects

Every LLM call is a service. Validation, prompt rendering, response parsing — all in one place.

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

LLM calls are slow. Never block a web request. Three queue tiers, typed retry rules.

```ruby
# Rate limits → retry with backoff
# Timeouts → retry 3x
# Content filter → discard + alert
# Budget exceeded → discard + alert

LLM::TriageTicketJob.perform_later(ticket_id: 42)
```

</td>
</tr>
<tr>
<td>

### 3. Model Routing

Cheap tasks get cheap models. Automatically. Budget caps prevent surprise bills.

```yaml
# config/llm.yml
routing:
  classification: cheap      # → GPT-4o-mini
  generation: standard       # → Claude Sonnet
  reasoning: expensive       # → Claude Opus

daily_budget_usd: 500.00
```

</td>
<td>

### 4. Eval Pipeline

Log every call to Braintrust. Build eval datasets from production. Score quality. Gate deploys on regressions.

```ruby
# Maturity ladder:
# Week 1  → Trace logging (automatic)
# Week 3  → Dataset curation
# Week 6  → LLM-as-judge scoring
# Week 8+ → CI regression gates
```

</td>
</tr>
<tr>
<td>

### 5. Prompts as Views

Prompts live in `app/prompts/` as ERB templates. Versioned in git. Tested independently. i18n support.

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

### 6. Testing Strategy

Stubs for CI. VCR for integration. Shared examples for consistency. No API keys needed in test.

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

## Quick Start (Your Rails App)

Once the skill is installed in Claude Code, it guides Claude to set up your app with these steps:

**1. Pick your gem**

```ruby
# Gemfile — choose one:

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

> The audit script scans your codebase for raw API calls, hardcoded prompts, missing cost tracking, and sync LLM calls in controllers — then tells you exactly what to fix.

## What's Inside

| Reference | What It Covers |
|-----------|---------------|
| [client-setup.md](references/client-setup.md) | ruby_llm, langchain-rb, ruby-openai, anthropic-rb wrappers — all returning the same normalized response shape |
| [service-patterns.md](references/service-patterns.md) | BaseService, Result monad, Traceable/Retryable/CostTrackable concerns, error taxonomy |
| [job-patterns.md](references/job-patterns.md) | Three-queue Sidekiq strategy, typed retry rules, batch processing, dead letter handling |
| [proxy-routing.md](references/proxy-routing.md) | config/llm.yml, model routing, shadow experiments, LiteLLM/Portkey, budget guardrails |
| [eval-pipeline.md](references/eval-pipeline.md) | Braintrust logging, LLM-as-judge, eval datasets from production, CI gates |
| [prompt-management.md](references/prompt-management.md) | ERB templates in app/prompts/, partials, i18n, prompt versioning via git SHA |
| [testing-guide.md](references/testing-guide.md) | WebMock stubs, VCR cassettes, shared RSpec examples, CI strategy |
| [generators.md](references/generators.md) | `llm:install` and `llm:service` Rails generators |

Plus: 3 generator templates, 4 migration templates, and a codebase audit script.

## Who This Is For

**Rails developers** adding LLM features to production apps. Not ML engineers. Not data scientists. If you know ActionMailer and ActiveJob, you already know the patterns — this skill just teaches Claude to use them for LLM calls too.

## Compatible With

| | Gem | Use Case |
|-|-----|----------|
| **Recommended** | [ruby_llm](https://github.com/crmne/ruby_llm) | Multi-provider, clean DSL, ActiveRecord integration |
| **For RAG** | [langchain-rb](https://github.com/patterns-ai-core/langchainrb) | Vector search, pgvector, embeddings, agents |
| **Direct** | [ruby-openai](https://github.com/alexrudall/ruby-openai) | OpenAI-only projects |
| **Direct** | [anthropic-rb](https://github.com/alexrudall/anthropic) | Anthropic-only projects |
| **Proxy** | [LiteLLM](https://github.com/BerriAI/litellm) / [Portkey](https://portkey.ai) | Multi-provider routing, cost tracking |
| **Evals** | [Braintrust](https://braintrust.dev) | Trace logging, quality scoring, CI gates |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The bar: every pattern must be production-tested. No toy examples. Every code block should be copy-pasteable into a real Rails app.

## License

[MIT](LICENSE) — Ruby on AI

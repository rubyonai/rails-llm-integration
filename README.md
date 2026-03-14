# Rails LLM Integration — Claude Skill

[![Ruby](https://img.shields.io/badge/Ruby-3.2%2B-red)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-7.1%2B-red)](https://rubyonrails.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Skill](https://img.shields.io/badge/Claude-Skill-blueviolet)](https://docs.anthropic.com/en/docs/claude-code/skills)

**Stop scattering raw API calls across your Rails app.** This Claude skill teaches production-grade LLM integration patterns that follow Rails conventions — treating AI calls the way Rails treats email (ActionMailer), jobs (ActiveJob), and config (database.yml). Works with **ruby_llm**, **langchain-rb**, **ruby-openai**, and **anthropic-rb**.

## The Problem

Every Rails team adding LLM features ends up with the same mess: OpenAI calls in controllers, prompts hardcoded as strings, no cost tracking, no retries, no testing strategy, and a mounting API bill with no visibility.

## The Solution

Six patterns that give your LLM integrations the same structure as every other Rails concern:

```ruby
# Before: raw API call buried in a controller
def create
  client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
  response = client.chat(parameters: {
    model: "gpt-4o", messages: [{ role: "user", content: "Describe #{@product.name}" }]
  })
  @product.update!(description: response.dig("choices", 0, "message", "content"))
end

# After: Rails conventions
LLM::GenerateDescriptionJob.perform_later(@product.id)
# Service handles prompt rendering, model routing, cost tracking, retries, and tracing.
```

## Installation

### Claude Code (CLI)

Copy this directory into your project's `.claude/skills/` folder:

```bash
cp -r rails-llm-integration/ your-rails-app/.claude/skills/rails-llm-integration/
```

### Manual Reference

Read `SKILL.md` for the architecture overview, then dive into the reference files as needed.

## What's Included

| File | Description |
|------|-------------|
| `SKILL.md` | Skill definition, architecture overview, core principles |
| `references/client-setup.md` | ruby_llm, langchain-rb, ruby-openai, anthropic-rb client wrappers, proxy client, normalized response shape |
| `references/service-patterns.md` | LLM::BaseService, Result objects, concerns, error taxonomy |
| `references/job-patterns.md` | ActiveJob conventions, queue strategy, batch processing, dead letters |
| `references/proxy-routing.md` | Model routing, cost optimization, budgets, shadow experiments |
| `references/eval-pipeline.md` | Braintrust integration, LLM-as-judge, eval datasets, CI gates |
| `references/prompt-management.md` | Prompts-as-views, ERB templates, versioning, i18n |
| `references/testing-guide.md` | WebMock stubs, VCR cassettes, shared examples, CI strategy |
| `references/generators.md` | Rails generator implementation for `llm:install` and `llm:service` |
| `templates/base_service.rb.tt` | Generator template for LLM::BaseService |
| `templates/base_job.rb.tt` | Generator template for LLM::BaseJob |
| `templates/llm.yml.tt` | Generator template for config/llm.yml |
| `templates/migrations/` | Migration templates for batches, dead letters, eval cases, experiment logs |
| `scripts/audit_llm_usage.rb` | Codebase scanner for LLM anti-patterns |

## The 6 Core Patterns

1. **Service Objects** — Every LLM call goes through an `LLM::BaseService` subclass with tracing, retries, and cost tracking built in.

2. **Async Jobs** — LLM calls run in ActiveJob by default. Three queue tiers: critical, standard, bulk. Typed retry rules per error class.

3. **Model Routing** — `config/llm.yml` maps task types to model tiers (cheap/standard/expensive). Classification gets GPT-4o-mini. Reasoning gets Claude Opus. Budget guardrails prevent surprise bills.

4. **Eval Pipeline** — Braintrust tracing on every call. Build eval datasets from production. LLM-as-judge scoring. CI regression gates.

5. **Prompts as Views** — ERB templates in `app/prompts/`, rendered with locals, versioned in git. System and user prompts in separate files. i18n support.

6. **Testing Strategy** — WebMock stubs for unit tests, VCR for integration, shared examples for consistency, nightly CI for real API eval runs.

## Quick Start

1. Add gems to your Gemfile (pick one approach):

```ruby
# Option A: ruby_llm (recommended — multi-provider, clean DSL)
gem "ruby_llm", "~> 1.0"
gem "redis", "~> 5.0"

# Option B: langchain-rb (for RAG, vector search, agents)
gem "langchainrb", "~> 0.19"
gem "pgvector", "~> 0.3"       # if using pgvector for RAG
gem "redis", "~> 5.0"

# Option C: provider-specific gems (direct wrappers)
gem "ruby-openai", "~> 7.0"
gem "anthropic", "~> 0.3"
gem "redis", "~> 5.0"
```

2. Run the install generator (or copy files manually from `templates/`):

```bash
rails generate llm:install    # See references/generators.md for setup
rails db:migrate
```

3. Add API keys to Rails credentials:

```bash
rails credentials:edit
# openai:
#   api_key: sk-...
# anthropic:
#   api_key: sk-ant-...
```

4. Create your first service:

```ruby
# app/services/llm/product_description_service.rb
module LLM
  class ProductDescriptionService < BaseService
    self.task_type = :generation

    private

    def validate_params!(params)
      raise ArgumentError, "product required" unless params[:product]
    end

    def prompt_template
      "product_descriptions/generate"
    end

    def parse_response(response)
      content = response.dig(:choices, 0, :message, :content)
      { description: content.strip }
    end
  end
end
```

5. Run the audit: `ruby scripts/audit_llm_usage.rb /path/to/your/app`

## Who This Is For

Rails developers building LLM-powered features. Not ML engineers, not data scientists — Rails devs who want conventions, not frameworks. If you know ActionMailer and ActiveJob, you already know the patterns.

## Compatible With

| Gem | Support |
|-----|---------|
| [ruby_llm](https://github.com/crmne/ruby_llm) | Full (recommended) |
| [langchain-rb](https://github.com/patterns-ai-core/langchainrb) | Full (RAG, vectors, agents) |
| [ruby-openai](https://github.com/alexrudall/ruby-openai) | Full (OpenAI direct) |
| [anthropic-rb](https://github.com/alexrudall/anthropic) | Full (Anthropic direct) |
| [LiteLLM](https://github.com/BerriAI/litellm) | Full (proxy routing) |
| [Portkey](https://portkey.ai) | Full (proxy routing) |
| [Braintrust](https://braintrust.dev) | Full (eval pipeline) |

## Contributing

1. Fork this repo
2. Create a feature branch
3. Add or update reference files
4. Submit a pull request

Focus on production-tested patterns. No toy examples. Every code block should be copy-pasteable into a real Rails app.

## License

MIT

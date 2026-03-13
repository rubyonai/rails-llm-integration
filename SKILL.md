---
name: rails-llm-integration
description: >
  Production-grade LLM integration patterns for Ruby on Rails applications.
  USE THIS SKILL when the user needs to: integrate OpenAI, Claude, or any LLM API
  into a Rails app; use ruby_llm gem or langchain-rb gem in Rails; build AI-powered
  features in Rails; manage prompts as templates; route between LLM models for cost
  optimization; run LLM calls as background jobs; set up Braintrust evals; use
  LiteLLM or Portkey as a proxy; track LLM costs; test AI features; audit LLM usage
  patterns; build RAG pipelines in Rails with langchain-rb; add classification,
  summarization, extraction, or generation features to Rails; manage LLM API keys
  and budgets; handle LLM errors and retries; or adopt conventions for LLM service
  objects similar to ActionMailer or ActiveJob patterns.
  Triggers on: LLM in Rails, OpenAI Rails integration, Claude API Ruby,
  Anthropic SDK Rails, AI features Rails, prompt engineering Ruby, model routing,
  LLM cost optimization, Braintrust Rails, eval pipeline Ruby, background LLM jobs,
  async AI calls, LLM service objects, prompt templates Rails, ruby-openai gem,
  anthropic-rb gem, ruby-llm gem, ruby_llm gem, langchain-rb gem, langchainrb,
  faraday LLM, LLM anti-patterns Rails, audit LLM calls, AI service objects,
  Rails AI conventions, RAG Rails, vector search Rails, pgvector Rails.
---

# Rails LLM Integration Skill

## What This Skill Does

Teaches Claude to write LLM integrations the Rails Way -- treating LLM calls like
first-class Rails citizens alongside ActionMailer (email), ActiveJob (background work),
and ActionController (HTTP). Instead of scattered API calls, you get conventions.

## When to Use

- Adding any AI/LLM feature to a Rails application
- Using ruby_llm gem, langchain-rb gem, ruby-openai, or anthropic-rb in Rails
- Setting up prompt management, model routing, or cost tracking
- Building eval pipelines with Braintrust
- Building RAG pipelines with langchain-rb and pgvector
- Auditing existing LLM usage for anti-patterns
- Testing AI-powered features

## Architecture Overview

```
app/
  services/
    llm/
      base_service.rb          # All LLM calls inherit from this
      concerns/                # Traceable, Retryable, CostTrackable
      product_description_service.rb
      ticket_triage_service.rb
      errors.rb                # Typed error hierarchy
      result.rb                # Result monad
  jobs/
    llm/
      base_job.rb              # Async LLM calls inherit from this
      generate_description_job.rb
  prompts/                     # Prompts as views (ERB templates)
    product_descriptions/
      generate.text.erb
      generate.system.erb
    ticket_triage/
      classify.text.erb
config/
  llm.yml                     # Model config like database.yml
  initializers/
    llm.rb                    # Boot-time config validation
lib/
  llm/
    client.rb                 # Client factory: LLM::Client.for(model)
    clients/
      openai_client.rb        # Wraps ruby-openai gem
      anthropic_client.rb     # Wraps anthropic-rb gem
      ruby_llm_client.rb      # Wraps ruby_llm gem (multi-provider)
      langchain_client.rb     # Wraps langchain-rb gem
      proxy_client.rb         # LiteLLM/Portkey via Faraday
      stub_client.rb          # Test double
    config.rb                 # Loads config/llm.yml
    router.rb                 # Task-based model routing
    cost_tracker.rb           # Redis-backed cost tracking
    prompt_renderer.rb        # ERB-based prompt rendering
db/
  migrate/
    create_llm_batches.rb     # Batch job tracking
    create_llm_dead_letters.rb # Permanent failure tracking
    create_llm_eval_cases.rb  # Eval dataset storage
    create_llm_experiment_logs.rb # Shadow experiment results
```

## Installation

```bash
rails generate llm:install       # Sets up everything above
rails generate llm:service ProductDescription generation  # Scaffold a new service
```

## Reference Files

| File | Read When You Need To... |
|------|--------------------------|
| `references/client-setup.md` | Wire up ruby_llm, langchain-rb, ruby-openai, anthropic-rb, or proxy clients (start here) |
| `references/service-patterns.md` | Build LLM service objects with Result, tracing, retries |
| `references/job-patterns.md` | Make LLM calls async with ActiveJob + Sidekiq |
| `references/proxy-routing.md` | Route between models, optimize costs, set budgets |
| `references/eval-pipeline.md` | Set up Braintrust evals and quality scoring |
| `references/prompt-management.md` | Manage prompts as ERB templates (prompts-as-views) |
| `references/testing-guide.md` | Test LLM features with stubs, VCR, and CI strategy |
| `references/generators.md` | Rails generators for `llm:install` and `llm:service` |
| `templates/migrations/` | Database schemas for batches, dead letters, eval cases |
| `scripts/audit_llm_usage.rb` | Scan a Rails app for LLM anti-patterns |

## Core Principles

1. **Rails conventions wrap LLM libraries** -- ruby_llm and langchain-rb are the engine,
   Rails patterns are the chassis. Use service objects, ActiveJob, ERB templates, and
   YAML config. The gem handles the API; the convention handles everything else.

2. **Async by default** -- Every LLM call goes through ActiveJob unless the user is
   actively waiting (streaming). Never block a web request on a 3-second API call.

3. **Cost-aware routing** -- Every call has an estimated cost. Route cheap tasks to
   cheap models. Set daily budgets. Alert before you hit them.

4. **Eval-first development** -- Log every call with Braintrust. Build eval datasets
   from production traces. Score quality automatically. Gate deployments on eval
   regressions.

5. **Prompts are views** -- Prompts live in `app/prompts/` as ERB templates, versioned
   in git, rendered with locals, tested independently from API calls.

6. **Errors are typed** -- RateLimitError, TimeoutError, ContentFilterError,
   BudgetExceededError. Each has its own retry and alerting strategy.

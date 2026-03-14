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

This skill gives Claude Code a set of Rails conventions for LLM calls so it generates consistent, structured code whenever you ask it to build AI features.

## What It Looks Like

```ruby
LLM::GenerateDescriptionJob.perform_later(product_id: @product.id)
```

Behind that one line, Claude generates this structure for you:

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

Same structure for every LLM feature in your app.

## Installation

```bash
cp -r rails-llm-integration/ your-rails-app/.claude/skills/rails-llm-integration/
```

Then open Claude Code in your Rails project and ask it to add an LLM feature:

```
Add AI-powered product descriptions to my app
Set up LLM service objects with cost tracking
Create a ticket classification service using ruby_llm
```

Claude reads the skill's reference docs and generates code following these conventions.

## Reference Docs

```
references/
  client-setup.md        # ruby_llm, langchain-rb, ruby-openai, anthropic-rb
  service-patterns.md    # BaseService, Result, concerns, error types
  job-patterns.md        # Sidekiq queues, retry rules, batch processing
  proxy-routing.md       # config/llm.yml, model routing, budget caps
  eval-pipeline.md       # Braintrust, LLM-as-judge, CI gates
  prompt-management.md   # ERB templates in app/prompts/
  testing-guide.md       # WebMock, VCR, shared examples, CI strategy
  generators.md          # llm:install and llm:service generators

templates/
  base_service.rb.tt     # BaseService with concerns
  base_job.rb.tt         # BaseJob with retry rules
  llm.yml.tt             # Model routing and budget config
  migrations/            # Batches, dead letters, eval cases, experiments

scripts/
  audit_llm_usage.rb     # Finds anti-patterns in your codebase
```

## Who This Is For

Rails developers adding LLM features to production apps. If you know ActionMailer and ActiveJob, you already know the patterns. This skill teaches Claude to use them for LLM calls.

## Covers

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

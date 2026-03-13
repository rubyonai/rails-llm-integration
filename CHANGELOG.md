# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-03-13

### Added

- SKILL.md with YAML frontmatter and architecture overview
- **Client Setup** — ruby_llm (recommended), langchain-rb (RAG), ruby-openai, anthropic-rb client wrappers with normalized response shape
- **Service Patterns** — LLM::BaseService with Traceable, Retryable, CostTrackable concerns; Result monad; typed error hierarchy
- **Job Patterns** — LLM::BaseJob with three-queue Sidekiq strategy, typed retry/discard rules, batch processing, dead letter handling
- **Proxy Routing** — config/llm.yml convention, LLM::Router with task-based model routing, shadow experiments, budget guardrails, Redis-backed cost tracking
- **Eval Pipeline** — Braintrust integration, LLM-as-judge scoring, eval dataset curation, CI regression gates, four-level maturity ladder
- **Prompt Management** — Prompts-as-views in app/prompts/, ERB templates with partials, i18n support, prompt versioning via git SHA
- **Testing Guide** — WebMock stubs, VCR cassettes, shared RSpec examples, quality threshold assertions, CI strategy
- **Generators** — Rails generator implementations for `llm:install` and `llm:service`
- **Templates** — base_service.rb.tt, base_job.rb.tt, llm.yml.tt, 4 migration templates
- **Audit Script** — Codebase scanner detecting 5 categories of LLM anti-patterns
- **Build Script** — Packages skill as .skill zip file for distribution

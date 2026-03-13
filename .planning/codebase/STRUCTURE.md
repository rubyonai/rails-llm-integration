# Codebase Structure

## Directory Layout

```
rails-llm-integration/
├── .claude/                    # Claude Code configuration
├── .planning/                  # GSD planning documents
│   └── codebase/              # Codebase analysis (this directory)
├── build/                      # Packaged skill output
│   └── rails-llm-integration.skill
├── references/                 # Reference documentation (8 guides)
│   ├── client-setup.md        # ruby-openai, anthropic-rb, proxy client, normalized response
│   ├── eval-pipeline.md       # Braintrust, LLM-as-judge, eval datasets, CI gates
│   ├── generators.md          # Rails generators: llm:install, llm:service
│   ├── job-patterns.md        # BaseJob, queue tiers, batch processing, dead letters
│   ├── prompt-management.md   # ERB templates in app/prompts/, i18n, versioning
│   ├── proxy-routing.md       # Router, Config, CostTracker, shadow experiments, fallback
│   ├── service-patterns.md    # BaseService, Result, concerns, error taxonomy
│   └── testing-guide.md       # WebMock stubs, VCR, shared examples, CI strategy
├── scripts/                    # Utility scripts
│   ├── audit_llm_usage.rb     # Codebase scanner for LLM anti-patterns
│   └── build.sh               # Packages into build/rails-llm-integration.skill (zip)
├── templates/                  # Rails generator templates
│   ├── base_job.rb.tt         # BaseJob template with retry/discard rules
│   ├── base_service.rb.tt     # BaseService template with concerns
│   ├── llm.yml.tt             # LLM configuration YAML template
│   └── migrations/            # ActiveRecord migration templates
│       ├── create_llm_batches.rb.tt
│       ├── create_llm_dead_letters.rb.tt
│       ├── create_llm_eval_cases.rb.tt
│       └── create_llm_experiment_logs.rb.tt
├── SKILL.md                   # Skill definition with YAML frontmatter
├── README.md                  # Project overview and usage
├── LICENSE                    # MIT license
└── .gitignore
```

## Key Locations

| What | Where |
|------|-------|
| Skill definition | `SKILL.md` |
| Client setup patterns | `references/client-setup.md` |
| Service layer patterns | `references/service-patterns.md` |
| Job/async patterns | `references/job-patterns.md` |
| Proxy & routing | `references/proxy-routing.md` |
| Eval & quality | `references/eval-pipeline.md` |
| Prompt management | `references/prompt-management.md` |
| Testing strategy | `references/testing-guide.md` |
| Generator docs | `references/generators.md` |
| BaseService template | `templates/base_service.rb.tt` |
| BaseJob template | `templates/base_job.rb.tt` |
| Config template | `templates/llm.yml.tt` |
| Migration templates | `templates/migrations/` |
| Anti-pattern scanner | `scripts/audit_llm_usage.rb` |
| Build/package script | `scripts/build.sh` |

## Naming Conventions

- **Reference docs**: kebab-case (`client-setup.md`, `job-patterns.md`)
- **Templates**: snake_case with `.tt` extension (`base_service.rb.tt`)
- **Migration templates**: snake_case prefixed with `create_llm_` (`create_llm_batches.rb.tt`)
- **Scripts**: snake_case (`audit_llm_usage.rb`)

## Content Organization

This is a **Claude Skill** (documentation + templates project), not a runnable Rails application. It provides:

1. **Reference documentation** — Comprehensive guides for integrating LLMs into Rails apps
2. **Generator templates** — `.tt` files used by Rails generators to scaffold LLM infrastructure
3. **Utility scripts** — Audit and build tooling
4. **Skill metadata** — `SKILL.md` defines the skill for Claude Code consumption

All code examples live inline within reference docs and templates. There is no `lib/`, `app/`, or `spec/` directory — those are patterns described for the target Rails application.

# Contributing to Rails LLM Integration

Thanks for considering a contribution. This skill is built from production experience,
and we want to keep it that way.

## The Bar

Every pattern in this skill must be **production-tested**. If you haven't run it in a
real Rails app handling real traffic, it's not ready for this repo. We don't accept
patterns from tutorials, blog posts, or "should work in theory."

## What We're Looking For

- **New service patterns** — Have a production LLM service pattern that doesn't fit the
  existing examples? Open a PR with the pattern and where you've used it.
- **Gem coverage** — Better ruby_llm or langchain-rb integration patterns, especially
  edge cases you've hit in production.
- **Cost optimization strategies** — Real routing rules, shadow experiment results,
  budget guardrail improvements.
- **Eval patterns** — New Braintrust integration patterns, scoring strategies, CI gate
  configurations that caught real regressions.
- **Testing patterns** — Better stubs, VCR configurations, or CI strategies for LLM tests.

## How to Contribute

1. Fork this repo
2. Create a feature branch (`git checkout -b add-embedding-service-pattern`)
3. Make your changes
4. Test that the skill still packages correctly: `bash scripts/build.sh`
5. Submit a pull request

## Pull Request Guidelines

- **One pattern per PR** — Don't bundle unrelated changes.
- **Include context** — Explain where you've used this pattern and what problem it solves.
- **Code must be copy-pasteable** — Every Ruby code block should work when pasted into a
  Rails app with the right gems installed. No pseudocode.
- **Follow existing conventions** — Match the file structure, naming, and style of
  existing reference files.

## Reporting Issues

- **Pattern doesn't work** — File an issue with the error, your gem versions, and Rails version.
- **Pattern request** — Describe the use case and what you've tried so far.
- **Inaccurate content** — Point to the specific section and explain what's wrong.

## Code of Conduct

Be respectful. Be constructive. Focus on the work.

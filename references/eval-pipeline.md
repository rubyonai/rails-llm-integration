# Eval Pipeline

Braintrust eval integration for Rails. The maturity ladder: trace logging -> dataset
curation -> automated scoring -> regression gates in CI.

## Braintrust Logger as a Rails Concern

Wire tracing into every LLM call automatically:

```ruby
# lib/llm/trace_logger.rb
require "braintrust"

module LLM
  class TraceLogger
    def self.log(trace_data)
      return if Rails.env.test?

      Braintrust.log(
        project: project_name,
        input: trace_data[:input],
        output: trace_data[:output],
        expected: trace_data[:expected],
        scores: trace_data[:scores],
        metadata: {
          service: trace_data[:service],
          model: trace_data[:metadata]&.dig(:model),
          trace_id: trace_data[:trace_id],
          duration_ms: trace_data[:duration_ms],
          error: trace_data[:error],
          environment: Rails.env,
          git_sha: ENV["GIT_SHA"] || `git rev-parse HEAD`.strip
        },
        id: trace_data[:trace_id]
      )
    rescue => e
      # Never let eval logging break production
      Rails.logger.error("Braintrust logging failed: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end

    def self.project_name
      ENV.fetch("BRAINTRUST_PROJECT", Rails.application.class.module_parent_name.underscore)
    end
  end
end
```

Setup in an initializer:

```ruby
# config/initializers/braintrust.rb
Braintrust.configure do |config|
  config.api_key = Rails.application.credentials.braintrust_api_key
end if defined?(Braintrust) && !Rails.env.test?
```

## Capturing Production Traces as Eval Datasets

Build eval datasets from real production data:

```ruby
# lib/llm/eval/dataset_builder.rb
module LLM
  module Eval
    class DatasetBuilder
      # Capture a production call as an eval case
      def self.capture(service:, input:, output:, expected: nil, tags: [])
        EvalCase.create!(
          service_name: service,
          input_data: input,
          output_data: output,
          expected_data: expected,
          tags: tags,
          captured_at: Time.current,
          source: "production"
        )
      end

      # Export dataset for Braintrust
      def self.export(service:, limit: 100, tags: nil)
        scope = EvalCase.where(service_name: service)
        scope = scope.where("tags && ARRAY[?]::varchar[]", tags) if tags
        scope = scope.where.not(expected_data: nil)  # Only cases with ground truth

        scope.order(captured_at: :desc).limit(limit).map do |ec|
          {
            input: ec.input_data,
            expected: ec.expected_data,
            metadata: { id: ec.id, captured_at: ec.captured_at }
          }
        end
      end
    end
  end
end
```

### Annotating Cases with Ground Truth

```ruby
# lib/llm/eval/annotator.rb
module LLM
  module Eval
    class Annotator
      # Mark a production output as correct (human review)
      def self.approve(eval_case_id)
        ec = EvalCase.find(eval_case_id)
        ec.update!(expected_data: ec.output_data, annotated_at: Time.current)
      end

      # Mark with corrected output
      def self.correct(eval_case_id, corrected_output:)
        ec = EvalCase.find(eval_case_id)
        ec.update!(expected_data: corrected_output, annotated_at: Time.current)
      end
    end
  end
end
```

## LLM-as-Judge Scoring

Use an LLM to score other LLM outputs:

```ruby
# lib/llm/eval/judge.rb
module LLM
  module Eval
    class Judge
      JUDGE_MODEL = "claude-sonnet-4-6"

      # Score an output on multiple dimensions
      def self.score(input:, output:, criteria:)
        prompt = build_judge_prompt(input: input, output: output, criteria: criteria)

        client = LLM::Client.for(JUDGE_MODEL)
        response = client.chat(
          model: JUDGE_MODEL,
          messages: [{ role: "user", content: prompt }],
          temperature: 0.0
        )

        parse_scores(response.dig(:choices, 0, :message, :content))
      end

      # Default scoring criteria
      DEFAULT_CRITERIA = {
        relevance: "Does the output directly address the input? (0.0-1.0)",
        accuracy: "Is the information factually correct? (0.0-1.0)",
        completeness: "Does it cover all aspects of the request? (0.0-1.0)",
        tone: "Is the tone appropriate for the context? (0.0-1.0)"
      }.freeze

      private_class_method def self.build_judge_prompt(input:, output:, criteria:)
        criteria_text = (criteria || DEFAULT_CRITERIA).map { |name, desc|
          "- #{name}: #{desc}"
        }.join("\n")

        <<~PROMPT
          You are an expert evaluator. Score the following output on each criterion.
          Return ONLY a JSON object with criterion names as keys and float scores as values.

          INPUT:
          #{input.to_json}

          OUTPUT:
          #{output}

          CRITERIA:
          #{criteria_text}

          Return JSON only, no explanation.
        PROMPT
      end

      private_class_method def self.parse_scores(content)
        JSON.parse(content, symbolize_names: true).transform_values(&:to_f)
      rescue JSON::ParserError
        { parse_error: 0.0 }
      end
    end
  end
end
```

## Shadow Experiment Scoring

Automatically compare cheap vs expensive model outputs:

```ruby
# lib/llm/eval/shadow_scorer.rb
module LLM
  module Eval
    class ShadowScorer
      def self.score_recent(experiment_name:, days: 7)
        logs = LLM::ExperimentLog
          .where(experiment_name: experiment_name)
          .where("created_at > ?", days.days.ago)
          .where(primary_score: nil)

        logs.find_each do |log|
          scores = Judge.score(
            input: { prompt_hash: log.prompt_hash },
            output: log.shadow_output,
            criteria: nil
          )

          primary_scores = Judge.score(
            input: { prompt_hash: log.prompt_hash },
            output: log.primary_output,
            criteria: nil
          )

          log.update!(
            primary_score: primary_scores.values.sum / primary_scores.size,
            shadow_score: scores.values.sum / scores.size
          )
        end

        # Summary report
        scored = LLM::ExperimentLog
          .where(experiment_name: experiment_name)
          .where("created_at > ?", days.days.ago)
          .where.not(primary_score: nil)

        {
          experiment: experiment_name,
          sample_size: scored.count,
          primary_avg_score: scored.average(:primary_score)&.round(3),
          shadow_avg_score: scored.average(:shadow_score)&.round(3),
          primary_avg_cost: scored.average(:primary_cost)&.round(6),
          shadow_avg_cost: scored.average(:shadow_cost)&.round(6),
          quality_delta: (scored.average(:primary_score).to_f - scored.average(:shadow_score).to_f).round(3),
          cost_savings_pct: calculate_savings(scored)
        }
      end

      private_class_method def self.calculate_savings(scored)
        primary_total = scored.sum(:primary_cost)
        shadow_total = scored.sum(:shadow_cost)
        return 0 if primary_total.zero?
        ((primary_total - shadow_total) / primary_total * 100).round(1)
      end
    end
  end
end
```

## Eval Maturity Ladder

### Level 1: Trace Logging (Week 1)

Just log everything. No scoring yet.

```ruby
# Already done if you're using LLM::BaseService with Traceable concern.
# Every call is logged to Braintrust automatically.
```

### Level 2: Dataset Curation (Week 2-3)

Start capturing good examples from production:

```ruby
# In your service, after a successful call:
if @result.success? && should_capture_for_eval?
  LLM::Eval::DatasetBuilder.capture(
    service: self.class.name,
    input: params,
    output: @result.value
  )
end

# Have humans annotate in a simple admin UI or Rails console:
LLM::Eval::Annotator.approve(eval_case_id)
LLM::Eval::Annotator.correct(eval_case_id, corrected_output: { ... })
```

### Level 3: Automated Scoring (Week 4-6)

Run LLM-as-judge on your eval dataset:

```ruby
# lib/llm/eval/runner.rb
module LLM
  module Eval
    class Runner
      def self.run(service_name:, sample_size: 50)
        dataset = DatasetBuilder.export(service: service_name, limit: sample_size)
        service = service_name.constantize.new

        results = dataset.map do |case_data|
          output_result = service.call(**case_data[:input].symbolize_keys)
          next unless output_result.success?

          scores = Judge.score(
            input: case_data[:input],
            output: output_result.value,
            criteria: nil
          )

          {
            input: case_data[:input],
            expected: case_data[:expected],
            actual: output_result.value,
            scores: scores,
            avg_score: scores.values.sum / scores.size
          }
        end.compact

        avg = results.sum { |r| r[:avg_score] } / results.size
        {
          service: service_name,
          sample_size: results.size,
          average_score: avg.round(3),
          passing: avg >= 0.7,
          threshold: 0.7,
          results: results
        }
      end
    end
  end
end
```

### Level 4: CI Regression Gates (Week 8+)

Fail the build if eval scores drop:

```ruby
# spec/eval/llm_regression_spec.rb (run only in nightly CI)
RSpec.describe "LLM Eval Regression", :eval do
  it "ProductDescriptionService maintains quality threshold" do
    report = LLM::Eval::Runner.run(
      service_name: "LLM::ProductDescriptionService",
      sample_size: 20
    )

    expect(report[:average_score]).to be >= 0.7
    expect(report[:passing]).to be true
  end
end
```

## Rake Tasks

```ruby
# lib/tasks/llm_eval.rake
namespace :llm do
  namespace :eval do
    desc "Run eval suite for a service"
    task :run, [:service] => :environment do |_, args|
      report = LLM::Eval::Runner.run(service_name: args[:service])
      puts JSON.pretty_generate(report)
      exit(1) unless report[:passing]
    end

    desc "Score recent shadow experiments"
    task :shadow, [:experiment] => :environment do |_, args|
      report = LLM::Eval::ShadowScorer.score_recent(
        experiment_name: args[:experiment]
      )
      puts JSON.pretty_generate(report)
    end

    desc "Export eval dataset"
    task :export, [:service] => :environment do |_, args|
      dataset = LLM::Eval::DatasetBuilder.export(service: args[:service])
      puts JSON.pretty_generate(dataset)
    end

    desc "Show eval summary across all services"
    task summary: :environment do
      services = EvalCase.distinct.pluck(:service_name)
      services.each do |service|
        count = EvalCase.where(service_name: service).count
        annotated = EvalCase.where(service_name: service).where.not(expected_data: nil).count
        puts "#{service}: #{count} cases (#{annotated} annotated)"
      end
    end
  end
end
```

## Key Rules

1. **Never let eval logging break production** -- rescue everything in TraceLogger
2. **Eval datasets come from production** -- synthetic data misses real edge cases
3. **LLM-as-judge is good enough to start** -- perfect scoring comes later
4. **Score threshold is 0.7** -- adjust per service as you learn
5. **Shadow experiments prove routing changes** -- always measure before switching models
6. **CI gates are the endgame** -- but start with manual review

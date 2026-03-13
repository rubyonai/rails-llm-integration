# LLM Job Patterns

ActiveJob conventions for async LLM calls. The rule: **always async unless the user
is watching** (streaming).

## Queue Strategy

Three queues, three priorities:

| Queue | Use For | Sidekiq Weight |
|-------|---------|----------------|
| `llm_critical` | User-blocking work (chat responses, real-time classification) | 10 |
| `llm_calls` | Standard async work (generate descriptions, summarize) | 5 |
| `llm_bulk` | Batch operations (overnight processing, backfills) | 1 |

Sidekiq config:

```yaml
# config/sidekiq.yml
:queues:
  - [llm_critical, 10]
  - [llm_calls, 5]
  - [llm_bulk, 1]
  - [default, 3]

:concurrency: 10
```

## BaseJob

```ruby
# app/jobs/llm/base_job.rb
module LLM
  class BaseJob < ApplicationJob
    queue_as :llm_calls

    # Retry strategy by error type
    retry_on LLM::RateLimitError, wait: :polynomially_longer, attempts: 5
    retry_on LLM::TimeoutError, wait: 30.seconds, attempts: 3
    retry_on Net::OpenTimeout, wait: 1.minute, attempts: 3

    # Don't retry these -- they won't get better
    discard_on LLM::ContentFilterError
    discard_on LLM::AuthenticationError
    discard_on LLM::BudgetExceededError

    # Cost logging after every perform
    after_perform do |job|
      log_job_cost(job)
    end

    # Alert on permanent failures
    discard_on(LLM::Error) do |job, error|
      handle_permanent_failure(job, error)
    end

    private

    def log_job_cost(job)
      # Subclasses store cost in @result metadata
      return unless defined?(@result) && @result&.success?

      Rails.logger.info(
        "LLM Job Cost",
        job_class: self.class.name,
        job_id: job.job_id,
        model: @result.metadata[:model],
        trace_id: @result.metadata[:trace_id]
      )
    end

    def handle_permanent_failure(job, error)
      Rails.logger.error(
        "LLM Job Discarded",
        job_class: self.class.name,
        job_id: job.job_id,
        error_class: error.class.name,
        error_message: error.message
      )

      # Alert via your preferred channel
      ErrorNotifier.notify(
        error,
        context: {
          job_class: self.class.name,
          job_id: job.job_id,
          arguments: job.arguments
        }
      )
    end
  end
end
```

## Standard Async Job

The most common pattern -- fire and forget with a callback:

```ruby
# app/jobs/llm/generate_description_job.rb
module LLM
  class GenerateDescriptionJob < BaseJob
    queue_as :llm_calls

    def perform(product_id)
      product = Product.find(product_id)
      @result = LLM::ProductDescriptionService.new.call(product: product)

      if @result.success?
        product.update!(
          ai_description: @result.value[:description],
          ai_description_generated_at: Time.current,
          ai_model_used: @result.metadata[:model]
        )
      else
        raise @result.error  # Triggers retry logic
      end
    end
  end
end
```

Enqueue from anywhere:

```ruby
# In a controller
LLM::GenerateDescriptionJob.perform_later(product.id)

# In a model callback
after_create_commit -> { LLM::GenerateDescriptionJob.perform_later(id) }

# In a service
Product.needs_description.find_each do |product|
  LLM::GenerateDescriptionJob.perform_later(product.id)
end
```

## Critical Queue Job

For user-facing features where latency matters:

```ruby
# app/jobs/llm/triage_ticket_job.rb
module LLM
  class TriageTicketJob < BaseJob
    queue_as :llm_critical

    # Tighter retry budget for critical path
    retry_on LLM::RateLimitError, wait: 5.seconds, attempts: 2
    retry_on LLM::TimeoutError, wait: 10.seconds, attempts: 2

    def perform(ticket_id)
      ticket = SupportTicket.find(ticket_id)
      @result = LLM::TicketTriageService.new.call(ticket: ticket)

      if @result.success?
        ticket.update!(
          category: @result.value[:category],
          triaged_at: Time.current
        )
        RoutingService.assign_agent(ticket)
      else
        ticket.update!(category: "unclassified")
        Rails.logger.warn("Ticket #{ticket_id} triage failed, defaulting to unclassified")
      end
    end
  end
end
```

## Batch Job Pattern

For processing thousands of records overnight:

```ruby
# app/jobs/llm/bulk_description_job.rb
module LLM
  class BulkDescriptionJob < BaseJob
    queue_as :llm_bulk

    # Generous retry budget for batch work
    retry_on LLM::RateLimitError, wait: :polynomially_longer, attempts: 10

    def perform(batch_id)
      batch = LLM::Batch.find(batch_id)
      batch.update!(status: :processing, started_at: Time.current)

      products = Product.where(id: batch.record_ids).where(ai_description: nil)
      total = products.count
      completed = 0
      failed = 0

      products.find_each do |product|
        result = LLM::ProductDescriptionService.new.call(product: product)

        if result.success?
          product.update!(ai_description: result.value[:description])
          completed += 1
        else
          failed += 1
          batch.failures.create!(
            record_type: "Product",
            record_id: product.id,
            error_message: result.error.message
          )
        end

        # Update progress for monitoring
        batch.update!(
          completed_count: completed,
          failed_count: failed,
          progress_pct: ((completed + failed).to_f / total * 100).round(1)
        )

        # Respect rate limits in batch mode
        sleep(0.1) if completed % 10 == 0
      end

      batch.update!(status: :completed, finished_at: Time.current)
    end
  end
end
```

### Batch Model

```ruby
# app/models/llm/batch.rb
module LLM
  class Batch < ApplicationRecord
    self.table_name = "llm_batches"

    has_many :failures, class_name: "LLM::BatchFailure"

    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }

    def self.enqueue(record_ids:, job_class:)
      batch = create!(
        record_ids: record_ids,
        job_class: job_class.name,
        status: :pending,
        total_count: record_ids.size
      )
      job_class.perform_later(batch.id)
      batch
    end
  end
end
```

Usage:

```ruby
# Enqueue 1000 products for overnight processing
product_ids = Product.needs_description.limit(1000).pluck(:id)
batch = LLM::Batch.enqueue(record_ids: product_ids, job_class: LLM::BulkDescriptionJob)

# Monitor in console
batch.reload
# => #<LLM::Batch status: "processing", progress_pct: 45.2, completed_count: 452>
```

## Dead Letter Handling

Track permanently failed jobs for review:

```ruby
# app/models/llm/dead_letter.rb
module LLM
  class DeadLetter < ApplicationRecord
    self.table_name = "llm_dead_letters"

    scope :unresolved, -> { where(resolved_at: nil) }
    scope :recent, -> { where("created_at > ?", 7.days.ago) }

    def resolve!(resolution:)
      update!(resolved_at: Time.current, resolution: resolution)
    end

    def retry!
      job_class = job_class_name.constantize
      job_class.perform_later(*arguments)
      resolve!(resolution: "retried")
    end
  end
end
```

Wire it into BaseJob:

```ruby
# In LLM::BaseJob, update handle_permanent_failure:
def handle_permanent_failure(job, error)
  LLM::DeadLetter.create!(
    job_class_name: self.class.name,
    job_id: job.job_id,
    arguments: job.arguments,
    error_class: error.class.name,
    error_message: error.message,
    failed_at: Time.current
  )

  ErrorNotifier.notify(error, context: { job_class: self.class.name })
end
```

## Rake Tasks for Operations

```ruby
# lib/tasks/llm.rake
namespace :llm do
  desc "Show dead letter queue summary"
  task dead_letters: :environment do
    unresolved = LLM::DeadLetter.unresolved
    puts "Unresolved LLM failures: #{unresolved.count}"
    unresolved.group(:error_class).count.each do |error, count|
      puts "  #{error}: #{count}"
    end
  end

  desc "Retry all rate-limited dead letters"
  task retry_rate_limited: :environment do
    LLM::DeadLetter
      .unresolved
      .where(error_class: "LLM::RateLimitError")
      .find_each(&:retry!)
  end

  desc "Show batch job progress"
  task batch_status: :environment do
    LLM::Batch.processing.each do |batch|
      puts "Batch #{batch.id}: #{batch.progress_pct}% " \
           "(#{batch.completed_count}/#{batch.total_count}, " \
           "#{batch.failed_count} failures)"
    end
  end
end
```

## Key Rules

1. **Never call an LLM service directly from a controller** -- enqueue a job
2. **Exception: streaming responses** -- those bypass the job layer
3. **Always pass record IDs, not objects** -- jobs serialize to Redis
4. **Set queue based on urgency** -- critical/standard/bulk
5. **Log costs after every perform** -- no untracked LLM spend
6. **Dead letter everything that permanently fails** -- never silently drop

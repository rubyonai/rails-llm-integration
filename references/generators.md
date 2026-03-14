# Rails Generators

Install the full LLM stack with `rails generate llm:install` instead of copy-pasting files.

## Install Generator

```ruby
# lib/generators/llm/install_generator.rb
require "rails/generators"
require "rails/generators/base"

module Llm
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      class_option :skip_migrations, type: :boolean, default: false,
        desc: "Skip generating migration files"

      desc "Sets up the LLM integration stack for your Rails app"

      def create_config
        template "llm.yml", "config/llm.yml"
      end

      def create_initializer
        template "llm_initializer.rb", "config/initializers/llm.rb"
      end

      def create_service_layer
        # Core files
        template "errors.rb", "app/services/llm/errors.rb"
        template "result.rb", "app/services/llm/result.rb"
        template "base_service.rb", "app/services/llm/base_service.rb"

        # Concerns
        directory "concerns", "app/services/llm/concerns"
      end

      def create_job_layer
        template "base_job.rb", "app/jobs/llm/base_job.rb"
      end

      def create_client_layer
        template "client.rb", "lib/llm/client.rb"
        directory "clients", "lib/llm/clients"
        template "config.rb", "lib/llm/config.rb"
        template "router.rb", "lib/llm/router.rb"
        template "cost_tracker.rb", "lib/llm/cost_tracker.rb"
        template "token_counter.rb", "lib/llm/token_counter.rb"
        template "prompt_renderer.rb", "lib/llm/prompt_renderer.rb"
      end

      def create_prompt_directory
        empty_directory "app/prompts"
        create_file "app/prompts/.keep"
      end

      def create_migrations
        return if options[:skip_migrations]

        migration_template "migrations/create_llm_batches.rb",
          "db/migrate/create_llm_batches.rb"
        migration_template "migrations/create_llm_dead_letters.rb",
          "db/migrate/create_llm_dead_letters.rb"
        migration_template "migrations/create_llm_eval_cases.rb",
          "db/migrate/create_llm_eval_cases.rb"
        migration_template "migrations/create_llm_experiment_logs.rb",
          "db/migrate/create_llm_experiment_logs.rb"
      end

      def create_rake_tasks
        template "llm.rake", "lib/tasks/llm.rake"
      end

      def add_sidekiq_queues
        return unless File.exist?("config/sidekiq.yml")

        append_to_file "config/sidekiq.yml", <<~YAML

          # LLM job queues (added by rails generate llm:install)
          # Uncomment and adjust weights as needed:
          # :queues:
          #   - [llm_critical, 10]
          #   - [llm_calls, 5]
          #   - [llm_bulk, 1]
        YAML
      end

      def print_instructions
        say ""
        say "LLM integration installed!", :green
        say ""
        say "Next steps:"
        say "  1. Add API keys to Rails credentials:"
        say "       rails credentials:edit"
        say "       # Add: openai: { api_key: sk-... }"
        say "       # Add: anthropic: { api_key: sk-ant-... }"
        say ""
        say "  2. Run migrations:"
        say "       rails db:migrate"
        say ""
        say "  3. Add gems to Gemfile:"
        say "       gem 'ruby-openai', '~> 7.0'"
        say "       gem 'anthropic', '~> 0.3'"
        say "       gem 'redis', '~> 5.0'"
        say ""
        say "  4. Create your first service:"
        say "       rails generate llm:service ProductDescription generation"
        say ""
      end

      private

      def app_name
        Rails.application.class.module_parent_name
      end

      def migration_version
        "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
      end
    end
  end
end
```

## Service Generator

Scaffold a new LLM service + job + prompt template in one command:

```ruby
# lib/generators/llm/service_generator.rb
require "rails/generators"
require "rails/generators/base"

module Llm
  module Generators
    class ServiceGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      argument :task_type, type: :string, default: "generation",
        banner: "TASK_TYPE",
        desc: "Task type for model routing: classification, generation, extraction, summarization, reasoning"

      desc "Creates an LLM service, job, and prompt template"

      def create_service
        template "service.rb.tt", "app/services/llm/#{file_name}_service.rb"
      end

      def create_job
        template "job.rb.tt", "app/jobs/llm/#{file_name}_job.rb"
      end

      def create_prompts
        template "prompt.system.erb.tt", "app/prompts/#{file_name}/#{action_name}.system.erb"
        template "prompt.text.erb.tt", "app/prompts/#{file_name}/#{action_name}.text.erb"
      end

      def create_spec
        if File.directory?("spec")
          template "service_spec.rb.tt", "spec/services/llm/#{file_name}_service_spec.rb"
        end
      end

      private

      def action_name
        case task_type
        when "classification" then "classify"
        when "extraction" then "extract"
        when "summarization" then "summarize"
        else "generate"
        end
      end
    end
  end
end
```

### Service Template

```erb
<%# lib/generators/llm/templates/service.rb.tt %>
# frozen_string_literal: true

module LLM
  class <%= class_name %>Service < BaseService
    self.task_type = :<%= task_type %>

    private

    def validate_params!(params)
      # Add your parameter validation here, e.g.:
      # raise ArgumentError, "record required" unless params[:record]
    end

    def prompt_template
      "<%= file_name %>/<%= action_name %>"
    end

    def parse_response(response)
      content = response.dig(:choices, 0, :message, :content)
      raise LLM::InvalidResponseError, "Empty response" if content.blank?

      # Parse the response into a structured hash for your use case
      { result: content.strip }
    end
<% if task_type == "generation" %>
    def temperature = 0.7
    def max_tokens = 1024
<% elsif task_type == "classification" %>
    def temperature = 0.0
    def max_tokens = 50
<% else %>
    def temperature = 0.0
    def max_tokens = 1024
<% end %>
  end
end
```

### Spec Template

```erb
<%# lib/generators/llm/templates/service_spec.rb.tt %>
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LLM::<%= class_name %>Service do
  it_behaves_like "an LLM service", described_class do
    let(:valid_params) { { record: build(:record) } }
    let(:valid_response_content) { "Sample response for your service" }
  end

  describe "#call" do
    it "returns parsed result on success" do
      stub_llm_response(model: "gpt-4o-mini", content: "Sample response for your service")

      result = described_class.new.call(record: build(:record))

      expect(result).to be_success
      expect(result.value[:result]).to be_present
    end
  end
end
```

## Usage

```bash
# Install the full stack
rails generate llm:install

# Scaffold a new service
rails generate llm:service ProductDescription generation
rails generate llm:service TicketTriage classification
rails generate llm:service ArticleSummary summarization

# What gets created for each service:
#   app/services/llm/product_description_service.rb
#   app/jobs/llm/product_description_job.rb
#   app/prompts/product_description/generate.system.erb
#   app/prompts/product_description/generate.text.erb
#   spec/services/llm/product_description_service_spec.rb
```

## Key Points

1. **`rails g llm:install` is the entry point** -- one command sets up everything
2. **`rails g llm:service` scaffolds the full pattern** -- service + job + prompt + spec
3. **Task type determines defaults** -- classification gets temperature 0.0, generation gets 0.7
4. **Migrations are included** -- all referenced ActiveRecord models have schemas
5. **Generators follow Rails conventions** -- `source_root`, `template`, `directory`, `migration_template`

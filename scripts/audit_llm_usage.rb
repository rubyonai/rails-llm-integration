#!/usr/bin/env ruby
# frozen_string_literal: true

# LLM Usage Audit Script
#
# Scans a Rails codebase for LLM integration anti-patterns.
#
# Usage:
#   ruby scripts/audit_llm_usage.rb /path/to/rails/app
#
# Reports:
#   - Direct API client calls outside LLM::BaseService subclasses
#   - Synchronous LLM calls in controllers
#   - Hardcoded API keys
#   - Hardcoded prompt strings instead of templates
#   - Missing cost tracking

require "pathname"

class LLMAuditor
  SEVERITY_COLORS = {
    "HIGH" => "\e[31m",
    "MEDIUM" => "\e[33m",
    "LOW" => "\e[36m"
  }.freeze
  RESET = "\e[0m"

  # Patterns that indicate direct LLM client usage
  DIRECT_CLIENT_PATTERNS = [
    /OpenAI::Client\.new/,
    /Anthropic::Client\.new/,
    /Cohere::Client\.new/,
    /\.chat\(\s*model:/,
    /\.completions\.create/,
    /\.messages\.create/
  ].freeze

  # Patterns that indicate hardcoded API keys
  API_KEY_PATTERNS = [
    /sk-[a-zA-Z0-9]{20,}/,                            # OpenAI key format
    /sk-ant-[a-zA-Z0-9]{20,}/,                         # Anthropic key format
    /["'](?:openai|anthropic|cohere)_api_key["']\s*=>/,  # Key assignment
    /api_key\s*[:=]\s*["'][^"']{20,}["']/,              # Generic hardcoded key
    /Bearer\s+sk-/                                       # Bearer token with key
  ].freeze

  # Patterns that indicate hardcoded prompts
  HARDCODED_PROMPT_PATTERNS = [
    /(?:system|user)_prompt\s*=\s*["']{1}[^"']{100,}/,
    /messages\s*=\s*\[\s*\{\s*role:\s*["'](?:system|user)["']/,
    /content:\s*["']You are (?:a|an)/,
    /<<~(?:PROMPT|SYSTEM|TEXT)\b/
  ].freeze

  Finding = Struct.new(:file, :line, :severity, :category, :message, :suggestion, keyword_init: true)

  def initialize(app_path)
    @app_path = Pathname.new(app_path)
    @findings = []
    validate_path!
  end

  def run
    puts "Auditing LLM usage in: #{@app_path}\n\n"

    scan_direct_client_calls
    scan_sync_controller_calls
    scan_hardcoded_keys
    scan_hardcoded_prompts
    scan_missing_cost_tracking

    print_report
    print_summary
  end

  private

  def validate_path!
    unless @app_path.directory?
      abort "Error: #{@app_path} is not a valid directory"
    end
  end

  # -----------------------------------------------------------------
  # Check 1: Direct API client calls outside LLM::BaseService
  # -----------------------------------------------------------------

  def scan_direct_client_calls
    ruby_files.each do |file|
      next if inside_llm_service?(file)
      next if test_file?(file)

      lines = File.readlines(file)
      lines.each_with_index do |line, idx|
        DIRECT_CLIENT_PATTERNS.each do |pattern|
          next unless line.match?(pattern)

          @findings << Finding.new(
            file: relative(file),
            line: idx + 1,
            severity: "HIGH",
            category: "DIRECT_CLIENT",
            message: "Direct LLM API client call outside LLM::BaseService",
            suggestion: "Move this to an LLM::BaseService subclass in app/services/llm/"
          )
        end
      end
    end
  end

  # -----------------------------------------------------------------
  # Check 2: Synchronous LLM calls in controllers
  # -----------------------------------------------------------------

  def scan_sync_controller_calls
    controller_files.each do |file|
      lines = File.readlines(file)
      lines.each_with_index do |line, idx|
        # Direct service calls in controllers (should use jobs)
        if line.match?(/LLM::\w+Service\.new\.call/) || line.match?(/\.call\(.*product:|.*ticket:/)
          @findings << Finding.new(
            file: relative(file),
            line: idx + 1,
            severity: "MEDIUM",
            category: "SYNC_CONTROLLER",
            message: "Synchronous LLM service call in controller",
            suggestion: "Use LLM::*Job.perform_later instead (async by default)"
          )
        end

        # Direct API calls in controllers
        DIRECT_CLIENT_PATTERNS.each do |pattern|
          next unless line.match?(pattern)

          @findings << Finding.new(
            file: relative(file),
            line: idx + 1,
            severity: "HIGH",
            category: "SYNC_CONTROLLER",
            message: "Direct LLM API call in controller action",
            suggestion: "Create an LLM service + job, enqueue with perform_later"
          )
        end
      end
    end
  end

  # -----------------------------------------------------------------
  # Check 3: Hardcoded API keys
  # -----------------------------------------------------------------

  def scan_hardcoded_keys
    ruby_files(include_config: true).each do |file|
      next if file.to_s.end_with?("audit_llm_usage.rb") # Don't flag ourselves

      lines = File.readlines(file)
      lines.each_with_index do |line, idx|
        next if line.strip.start_with?("#") # Skip comments

        API_KEY_PATTERNS.each do |pattern|
          next unless line.match?(pattern)

          @findings << Finding.new(
            file: relative(file),
            line: idx + 1,
            severity: "HIGH",
            category: "HARDCODED_KEY",
            message: "Possible hardcoded API key detected",
            suggestion: "Use Rails.application.credentials or ENV variables"
          )
        end
      end
    end
  end

  # -----------------------------------------------------------------
  # Check 4: Hardcoded prompts instead of templates
  # -----------------------------------------------------------------

  def scan_hardcoded_prompts
    ruby_files.each do |file|
      next if test_file?(file)
      next if file.to_s.include?("prompts/") # Prompt templates are fine

      lines = File.read(file)
      HARDCODED_PROMPT_PATTERNS.each do |pattern|
        lines.scan(pattern).each do
          # Find the line number
          line_num = lines[0...(lines.index(pattern))].count("\n") + 1 rescue 0

          @findings << Finding.new(
            file: relative(file),
            line: line_num,
            severity: "MEDIUM",
            category: "HARDCODED_PROMPT",
            message: "Hardcoded prompt string (should be in app/prompts/)",
            suggestion: "Move to app/prompts/ as an ERB template, use LLM::PromptRenderer"
          )
        end
      end
    end
  end

  # -----------------------------------------------------------------
  # Check 5: Missing cost tracking
  # -----------------------------------------------------------------

  def scan_missing_cost_tracking
    service_files.each do |file|
      content = File.read(file)

      # Check if it inherits from BaseService
      next unless content.match?(/class\s+\w+\s*<\s*(?:LLM::)?BaseService/)

      # BaseService includes CostTrackable, so subclasses are fine
      # But check for services that make LLM calls without inheriting BaseService
    end

    # Find classes making LLM calls without CostTrackable
    ruby_files.each do |file|
      next if test_file?(file)
      content = File.read(file)

      has_llm_call = DIRECT_CLIENT_PATTERNS.any? { |p| content.match?(p) }
      has_cost_tracking = content.include?("CostTrackable") || content.include?("track_cost")
      inherits_base = content.match?(/< (?:LLM::)?BaseService/)

      if has_llm_call && !has_cost_tracking && !inherits_base
        @findings << Finding.new(
          file: relative(file),
          line: 1,
          severity: "MEDIUM",
          category: "NO_COST_TRACKING",
          message: "LLM calls without cost tracking",
          suggestion: "Include LLM::Concerns::CostTrackable or inherit from LLM::BaseService"
        )
      end
    end
  end

  # -----------------------------------------------------------------
  # File helpers
  # -----------------------------------------------------------------

  def ruby_files(include_config: false)
    patterns = ["app/**/*.rb", "lib/**/*.rb"]
    patterns << "config/**/*.rb" if include_config
    patterns.flat_map { |p| Dir.glob(@app_path.join(p)) }
  end

  def controller_files
    Dir.glob(@app_path.join("app/controllers/**/*.rb"))
  end

  def service_files
    Dir.glob(@app_path.join("app/services/llm/**/*.rb"))
  end

  def inside_llm_service?(file)
    file.to_s.include?("app/services/llm/")
  end

  def test_file?(file)
    file.to_s.match?(%r{spec/|test/|_spec\.rb|_test\.rb})
  end

  def relative(file)
    Pathname.new(file).relative_path_from(@app_path).to_s
  end

  # -----------------------------------------------------------------
  # Reporting
  # -----------------------------------------------------------------

  def print_report
    if @findings.empty?
      puts "No LLM anti-patterns found. Your codebase follows Rails LLM conventions.\n\n"
      return
    end

    grouped = @findings.group_by(&:category)

    grouped.each do |category, findings|
      puts "#{category_label(category)}"
      puts "-" * 70

      findings.sort_by(&:severity).each do |f|
        color = SEVERITY_COLORS[f.severity] || ""
        puts "  #{color}[#{f.severity}]#{RESET} #{f.file}:#{f.line}"
        puts "    #{f.message}"
        puts "    Fix: #{f.suggestion}"
        puts
      end
    end
  end

  def print_summary
    puts "=" * 70
    puts "AUDIT SUMMARY"
    puts "=" * 70

    total = @findings.size
    high = @findings.count { |f| f.severity == "HIGH" }
    medium = @findings.count { |f| f.severity == "MEDIUM" }
    low = @findings.count { |f| f.severity == "LOW" }

    puts "  Total findings: #{total}"
    puts "  #{SEVERITY_COLORS['HIGH']}HIGH:   #{high}#{RESET}"
    puts "  #{SEVERITY_COLORS['MEDIUM']}MEDIUM: #{medium}#{RESET}"
    puts "  #{SEVERITY_COLORS['LOW']}LOW:    #{low}#{RESET}"
    puts

    if high > 0
      puts "Action required: Fix HIGH severity findings before deploying."
    elsif medium > 0
      puts "Recommended: Address MEDIUM findings to follow Rails LLM conventions."
    else
      puts "Looking good! Only minor suggestions found."
    end

    exit(1) if high > 0
  end

  def category_label(category)
    {
      "DIRECT_CLIENT" => "Direct API Client Calls (use LLM::BaseService)",
      "SYNC_CONTROLLER" => "Synchronous LLM Calls in Controllers (use ActiveJob)",
      "HARDCODED_KEY" => "Hardcoded API Keys (use credentials/ENV)",
      "HARDCODED_PROMPT" => "Hardcoded Prompts (use app/prompts/ templates)",
      "NO_COST_TRACKING" => "Missing Cost Tracking (use CostTrackable)"
    }.fetch(category, category)
  end
end

# -----------------------------------------------------------------
# CLI Entry Point
# -----------------------------------------------------------------

if ARGV.empty?
  puts "Usage: ruby #{$PROGRAM_NAME} /path/to/rails/app"
  puts
  puts "Scans a Rails codebase for LLM integration anti-patterns:"
  puts "  - Direct API client calls outside LLM::BaseService"
  puts "  - Synchronous LLM calls in controllers"
  puts "  - Hardcoded API keys"
  puts "  - Hardcoded prompt strings"
  puts "  - Missing cost tracking"
  exit(1)
end

LLMAuditor.new(ARGV[0]).run

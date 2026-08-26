# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create

# Expose a `rubocop` task when the gem is installed, without making the test
# task depend on it (CI runs tests without rubocop present).
begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
  task default: %i[test rubocop]
rescue LoadError
  task default: :test
end

require "minitest/test_task"

# Unit tests: no GPIO hardware or libgpiod needed (this is what CI runs).
Minitest::TestTask.create do |t|
  t.test_globs = ["test/rgpio/**/*_test.rb"]
end

# Hardware tests over a jumper-wired pin pair, output first:
#   RGPIO_LOOPBACK=17:27 rake integration
# Every test skips when RGPIO_LOOPBACK is unset.
Minitest::TestTask.create(:integration) do |t|
  t.test_globs = ["test/integration/**/*_test.rb"]
end

# Expose a `rubocop` task when the gem is installed, without making the test
# task depend on it (CI runs tests without rubocop present).
begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
  task default: %i[test rubocop]
rescue LoadError
  task default: :test
end

require_relative "../test_helper"
require "rgpio"

# The shared `open` class method: block form closes, plain form returns.
class OpenableTest < Minitest::Test
  class Resource
    extend Rgpio::Openable

    attr_reader :args, :kwargs

    def initialize(*args, **kwargs)
      @args = args
      @kwargs = kwargs
      @closed = false
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def test_without_a_block_returns_the_open_instance
    resource = Resource.open(18, frequency: 50)

    assert_equal [18], resource.args
    assert_equal({ frequency: 50 }, resource.kwargs)
    refute_predicate resource, :closed?
  end

  def test_with_a_block_returns_its_value_and_closes
    seen = nil
    result = Resource.open(4) do |resource|
      seen = resource
      :done
    end

    assert_equal :done, result
    assert_predicate seen, :closed?
  end

  def test_closes_even_when_the_block_raises
    seen = nil
    assert_raises(RuntimeError) do
      Resource.open { |resource| seen = resource; raise "boom" } # rubocop:disable Style/Semicolon
    end

    assert_predicate seen, :closed?
  end
end

require_relative "../test_helper"
require "rgpio"

# The shared close / closed?: release once, then nothing.
class CloseableTest < Minitest::Test
  class Resource
    include Rgpio::Closeable

    attr_reader :releases

    def initialize(fail: false)
      @releases = 0
      @fail = fail
    end

    def use
      assert_open!
      :used
    end

    private

    def release_resources
      @releases += 1
      raise "release failed" if @fail
    end
  end

  def test_close_releases_once
    resource = Resource.new
    refute_predicate resource, :closed?

    resource.close
    resource.close

    assert_predicate resource, :closed?
    assert_equal 1, resource.releases
  end

  def test_a_failed_release_still_leaves_it_closed
    resource = Resource.new(fail: true)
    assert_raises(RuntimeError) { resource.close }

    assert_predicate resource, :closed?
    resource.close
    assert_equal 1, resource.releases, "a second close does not retry the release"
  end

  def test_use_after_close_raises
    resource = Resource.new
    assert_equal :used, resource.use
    resource.close

    error = assert_raises(Rgpio::Error) { resource.use }
    assert_match(/Resource is closed/, error.message)
  end
end

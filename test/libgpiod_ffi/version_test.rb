# frozen_string_literal: true

require_relative "../test_helper"
require "libgpiod_ffi/version"

class VersionTest < Minitest::Test
  def test_version_is_semantic
    assert_match(/\A\d+\.\d+\.\d+\z/, LibgpiodFFI::VERSION)
  end
end

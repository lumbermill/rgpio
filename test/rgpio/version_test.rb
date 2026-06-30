# frozen_string_literal: true

require_relative "../test_helper"
require "rgpio/version"

class VersionTest < Minitest::Test
  def test_version_is_semantic
    assert_match(/\A\d+\.\d+\.\d+\z/, Rgpio::VERSION)
  end
end

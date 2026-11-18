module Rgpio
  # The `open` class method shared by classes that hold a kernel resource:
  # with a block, the instance is yielded and closed afterwards, and the
  # block's value returned; without one, the open instance is returned.
  module Openable
    # @return [Object] the instance, or the block's value
    def open(...)
      resource = new(...)
      return resource unless block_given?

      begin
        yield resource
      ensure
        resource.close
      end
    end
  end
end

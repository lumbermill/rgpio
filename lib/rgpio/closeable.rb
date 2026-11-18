module Rgpio
  # `close` / `closed?` for classes that hold a kernel resource: close runs
  # the class's #release_resources once, and later calls do nothing.
  #
  # The flag is set before releasing, so a release that raises part-way still
  # leaves the object closed rather than half-open and retried.
  module Closeable
    # Release what this object holds. Safe to call multiple times.
    def close
      return if closed?

      @closed = true
      release_resources
      nil
    end

    def closed?
      @closed || false
    end

    private

    # What #close releases; each class defines its own.
    def release_resources; end

    def assert_open!
      raise Error, "#{self.class} is closed" if closed?
    end
  end
end

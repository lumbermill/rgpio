module Rgpio
  class SoftwarePWM
    # The forked-child side of {SoftwarePWM} (`process: true`, or `:auto` on a
    # single-core board): the parent sends settings down a pipe and the child
    # owns the line and generates. See SoftwarePWM's class comment for why.
    module ProcessMode
      # Pipe ends held by this process for every child it has forked. A child
      # closes the ones it inherited, or another channel's child would keep that
      # channel's pipe open after its parent closed it, and that channel's child
      # would never see the end of its input.
      @parent_ends = []
      @parent_ends_lock = Mutex.new

      class << self
        # @api private
        def register_parent_ends(*ios)
          @parent_ends_lock.synchronize { @parent_ends.concat(ios) }
        end

        # @api private
        def unregister_parent_ends(*ios)
          @parent_ends_lock.synchronize { @parent_ends -= ios }
        end

        # @api private — called in a fresh child only
        def close_inherited_parent_ends
          @parent_ends.each { |io| io.close unless io.closed? }
          @parent_ends = []
        end
      end

      private

      # --- process mode: parent side -------------------------------------- #

      # Fork the child and wait until it holds the line, so that a pin already in
      # use raises here, from new, exactly as it does in thread mode.
      def start_child(chip, consumer)
        commands_in, @commands = IO.pipe
        @replies, replies_out = IO.pipe
        [commands_in, @commands, @replies, replies_out].each(&:binmode)

        @pid = fork do
          child_main(chip, consumer, commands_in, replies_out)
        end
        commands_in.close
        replies_out.close
        ProcessMode.register_parent_ends(@commands, @replies)
        await_child_ready
      end

      def await_child_ready
        return if @replies.read(1) == "R"

        error = begin
          Marshal.load(@replies.read) # rubocop:disable Security/MarshalLoad -- our own child
        rescue StandardError
          Error.new("SoftwarePWM child for GPIO#{@gpio} exited during start-up")
        end
        stop_child
        @closed = true
        raise error
      end

      def send_settings
        running, frequency, duty = @mutex.synchronize { [@running ? 1.0 : 0.0, @frequency.to_f, @duty] }
        @commands.syswrite([running, frequency, duty].pack(RECORD_FORMAT))
      rescue Errno::EPIPE, IOError
        raise Error, "SoftwarePWM child for GPIO#{@gpio} has exited"
      end

      def stop_child
        @commands.close unless @commands.closed?
        Process.wait(@pid)
        @replies.close unless @replies.closed?
        ProcessMode.unregister_parent_ends(@commands, @replies)
      rescue Errno::ECHILD
        nil
      end

      # --- process mode: child side --------------------------------------- #

      def child_main(chip, consumer, commands_in, replies_out)
        ProcessMode.close_inherited_parent_ends
        @commands.close
        @replies.close
        # Ctrl-C reaches the whole process group. The parent decides when this
        # child stops — by closing the pipe, or by exiting.
        %w[INT TERM HUP].each { |signal| trap(signal, "IGNORE") }
        Process.setproctitle("rgpio SoftwarePWM GPIO#{@gpio}")
        @commands_in = commands_in
        @reply = replies_out
        begin
          @request = request_line(chip || Chip.new, consumer)
        rescue Exception => e # rubocop:disable Lint/RescueException -- report anything, then exit!
          replies_out.write("E#{Marshal.dump(e)}")
          exit!(1)
        end
        replies_out.write("R")
        serve
        exit!(0)
      rescue Exception # rubocop:disable Lint/RescueException -- never run the parent's at_exit hooks
        exit!(1)
      end

      # Apply settings as they arrive; generate while told to run.
      def serve
        @record = String.new(capacity: RECORD_SIZE, encoding: Encoding::BINARY)
        @eof = false
        GC.start
        GC.disable
        until @eof
          read_record_blocking
          next unless @running && !@eof

          generate
          @request.set_value(@gpio, :inactive)
          @reply.write("A") unless @eof
        end
      ensure
        @request&.set_value(@gpio, :inactive)
        @request&.release
      end

      def read_record_blocking
        @commands_in.sysread(RECORD_SIZE, @record)
        apply_record
      rescue EOFError
        @eof = true
        @running = false
      end

      # Called by the generating loop after each falling edge, in the child only.
      # Takes the newest settings without blocking and allocating nothing when
      # there are none, then collects if the heap is running out — this is the
      # low phase, so a collection here delays nothing that is on the line.
      def between_cycles
        return unless @process

        loop do
          got = @commands_in.read_nonblock(RECORD_SIZE, @record, exception: false)
          break if got == :wait_readable

          if got.nil?
            @eof = true
            @running = false
            break
          end
          apply_record
        end
        return unless GC.stat(:heap_free_slots) < CHILD_GC_FREE_SLOTS

        GC.enable
        GC.start(full_mark: false, immediate_sweep: true)
        GC.disable
      end

      def apply_record
        running, frequency, duty = @record.unpack(RECORD_FORMAT)
        @mutex.synchronize do
          @running = running > 0.5
          @frequency = frequency
          @duty = duty
        end
      end
    end
  end
end

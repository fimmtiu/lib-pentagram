module Pentagram
  class SignalBroker
    def self.handle_queued_signals
      handled = []
      unhandled = []
      while IO.select([@@reader], nil, nil, 0)
        sig = Signal.signame(@@reader.gets.to_i).upcase.to_sym
        if @@brokers.include?(sig) && @@brokers[sig].handle_signal
          logger.info("handled SIG#{sig}")
          handled << sig
        else
          logger.info("received unhandled SIG#{sig}")
          unhandled << sig
        end
      end
      [ handled, unhandled ]
    end

    def self.logger
      @@logger
    end

    def self.logger=(logger)
      @@logger = logger
    end

    def self.register_brokers(signals = nil)
      if signals.nil?
        # signals.nil? means that we are attempting to execute our default 'register all signal brokers' -- but we only
        # want to execute this default action if no custom signal handling has been done. Check whether @@brokers is
        # defined: if it is, then clearly some sort of signal handling has already been done, in which case we abort.
        return if defined?(@@brokers)
        # While it is possible, it isn't generally useful to automatically handle SIGEXIT at the framework level,
        # because we can't handle SIGEXIT signals within our normal flow. This is because it is an internally generated
        # 'virtual' signal that is triggered the instant before the ruby script exits (i.e., it isn't really
        # 'asynchronous', it's more like it is 'scheduled').
        #
        # Therefore, we remove SIGEXIT from our list of signals trapped by default. SIGEXIT is definitely still useful
        # (just not at the default framework level), so the intent is for individual daemons to trap('EXIT') when
        # useful to do so, or they can override this by passing in ::Signal.list.keys as the 'signals' parameter to
        # this method.
        #
        # We also remove SIGCHLD from our list of signals-trapped-by-default due to the expectation that _generally_
        # the user will prefer the system default handling of SIGCHLD (which is typically to IGNORE it) rather than to
        # have it treated as an unhandled signal.
        #
        # If you want SIGCHLD to be trapped by the framework just activate it _after_ Pentagram::Daemon initialization:
        #
        #   def initialize
        #     super
        #     Pentagram::SignalBroker.register_brokers(['CHLD'])
        #     ...
        #   end
        #
        signals = ::Signal.list.keys - ['CHLD', 'CLD', 'EXIT']
      end
      @@brokers ||= {}
      @@reader, @@writer = IO.pipe unless defined?(@@reader) && defined?(@@writer)
      signals.each do |sig|
        begin
          sig = sig.upcase.to_sym
          @@brokers[sig] ||= SignalBroker.new(sig)
        rescue ArgumentError, Errno::EINVAL => e
          # We attempt to register signal brokers for everything, but silently ignore all of the signals that we are
          # not permitted to trap:
          #   SIGILL, SIGFPE, SIGKILL, SIGSTOP, etc.
        end
      end
    end

    def self.register_handler(sig, method)
      sig = sig.upcase.to_sym
      raise ArgumentError.new("unknown signal '#{sig}'") unless @@brokers.include?(sig)
      @@brokers[sig] << method
    end

    def self.select(read_fd, write_fd = nil, error_fd = nil, timeout = nil)
      read_fd ||= []
      read_fd << @@reader
      ready_io = IO.select(read_fd, write_fd, error_fd, timeout)
      ready_io.first.delete(@@reader) unless ready_io.nil?
      ready_io
    end

    def initialize(sig)
      @handlers = []
      @signal = sig.upcase.to_sym
      trap(@signal) { |signo| @@writer.puts(signo) }
      logger.debug("SignalBroker[#{@signal}] registered")
    end

    def <<(method)
      raise ArgumentError.new("#{method} has arity #{method.arity} instead of 1") unless method.arity == 1
      @handlers << method
      logger.debug("SignalBroker[#{@signal}] registered signal handler #{method.inspect}")
    end

    def handle_signal
      @handlers.each do |method|
        logger.debug("SignalBroker[#{@signal}] calling handler #{method.inspect}")
        method.call(@signal)
      end
      return @handlers.length > 0
    end

    def logger
      self.class.logger
    end
  end
end

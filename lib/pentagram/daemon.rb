require 'etc'
require 'logger'
require 'optparse'

module Pentagram
  class Daemon
    attr_reader :logger, :option_parser

    def self.enqueue_signal(sig)
      @@signal_queue ||= []
      @@signal_queue << sig
    end

    def self.register_signal_handler(sig, method)
      sig = sig.to_sym unless sig.nil?
      raise ArgumentError.new("unknown signal '#{sig}'") unless @@signal_handlers.include?(sig)
      return if @@signal_handlers[sig].include?(method)
      @@signal_handlers[sig] << method
    end

    def initialize
      @@continue = true unless defined?(@@continue)
      @@signal_handlers ||= {}
      [:HUP, :INT, :TERM, :USR1, :USR2].each { |sig| @@signal_handlers[sig] ||= [] }
      @@signal_queue ||= []

      # Note that both @logger and @options are fairly commonly defined in sub-classes of Pentagram::Daemon, so there
      # is a decent chance that the below statements do not hold (they are only meant as trivial defaults).
      @logger ||= Logger.new($stdout)
      @options ||= {}
      option_parser = OptionParser.new

      option_parser.separator('');
      option_parser.separator('Arguments:')

      option_parser.on('-?', '-h', '--help', 'show application usage information') do
        puts option_parser
        Kernel.exit(0)
      end

      @options[:daemonize] = false unless @options.include?(:daemonize)
      option_default = @options[:daemonize] ? 'daemonize to background' : 'stay in the foreground'
      option_parser.on(
        '-d', '--daemonize',
        "daemonize to background (default: #{option_default})"
      ) do |b|
        @options[:daemonize] = true
      end

      @options[:once] = false unless @options.include?(:once)
      option_default = @options[:once] ? 'execute only once' : 'loop execution until interrupted'
      option_parser.on(
        '--once',
        "only execute the main program loop once, do not repeat (default: #{option_default})"
      ) do |b|
        @options[:once] = true
      end

      @options[:pid_file] ||= nil
      option_default = @options[:pid_file] || 'no pidfile will be created'
      option_parser.on(
        '--pid-file FILE',
        "specify a pidfile that will be overwritten to contain the PID of this process (default: #{option_default})"
      ) do |s|
        @options[:pid_file] = s
      end

      @options[:sleep] ||= 10
      option_parser.on(
        '--sleep SECONDS', Float,
        "sleep this many seconds in-between main program loop runs (default: #{@options[:sleep]}s)"
      ) do |f|
        raise OptionParser::InvalidArgument, "sleep time must be greater than or equal to zero" if f < 0
        @options[:sleep] = f
      end

      @options[:user] ||= nil
      option_default = @options[:user] || 'do not drop privileges'
      option_parser.on(
        '--user USER',
        "drop privileges to user USER after initialization (default: #{option_default})"
      ) do |s|
        begin
          @options[:user] = Etc.getpwnam(s)
        rescue ArgumentError => e
          raise OptionParser::InvalidArgument, "user must be a valid system user: #{e.to_s}"
        end
      end

      @options[:verbose] = false unless @options.include?(:verbose)
      option_default = @options[:verbose] ? 'enabled' : 'disabled'
      option_parser.on(
        '-v', '--verbose',
        "enable verbose output (default: #{option_default})"
      ) do |b|
        @options[:verbose] = true
      end

      option_parser.on('-V', '--version', 'display application version information') do
        puts option_parser.ver
        Kernel.exit(0)
      end
    end

    def hook_continue?
      while @@signal_queue.length > 0 do
        sig = @@signal_queue.shift
        logger.info("signal received: SIG#{sig.to_s}")

        # By default (if we don't have any handlers registered for this signal), we simply exit. If there _are_
        # handlers registered then we take no action, leaving it to the registered handlers to decide what to do with
        # the signal.
        if @@signal_handlers.include?(sig) && (@@signal_handlers[sig].length > 0)
          @@signal_handlers[sig].each { |h| h.call(sig) }
        else
          @@continue = false
        end
      end
      return (@@continue && (@options[:once] == false))
    end

    def hook_pre_main; end

    def hook_main; end

    def hook_post_main; end

    def hook_privileged; end

    def parse_arguments!
      option_parser.parse!()
    end

    private def pid_file_valid?(path)
      pid = nil
      begin
        File.open(path, 'r') { |pid_file| pid = pid_file.read.to_i }
        if pid.nil? || pid == 0
          logger.debug("pidfile #{path} does not contain a valid pid")
          return false
        end
      rescue Errno::ENOENT
        logger.debug("pidfile #{path} does not exist")
        return false
      rescue SystemCallError => e
        logger.error("pidfile #{path} could not be accessed: #{e}")
        Kernel.exit(1)
      end
      begin
        Process.kill(0, pid)
        logger.debug("pidfile #{path} contains valid pid (#{pid})")
        return true
      rescue Errno::ESRCH
        logger.debug("pidfile #{path} contains stale pid (#{pid})")
        return false
      rescue SystemCallError => e
        logger.error("pidfile #{path} contains inaccessible pid (#{pid}): #{e}")
        Kernel.exit(1)
      end
    end

    def run
      begin
        parse_arguments!()
      rescue OptionParser::InvalidOption, OptionParser::InvalidArgument, OptionParser::MissingArgument => e
        puts e.to_s
        puts
        puts option_parser
        Kernel.exit(2)
      end

      if @options[:daemonize]
        GC.start
        Kernel.exit(0) if not Process.fork.nil?

        Process.setsid
        Kernel.exit(0) if not Process.fork.nil?

        $stdin.reopen(File.open('/dev/null', 'r'))
        $stdout.reopen(File.open('/dev/null', 'w'))
        $stderr.reopen(File.open('/dev/null', 'w'))
      end
      logger.level = logger.class.const_get(:INFO)
      logger.level = logger.class.const_get(:DEBUG) if @options[:verbose]
      @options.each { |k,v| logger.debug("options[#{k}] = #{v}") } if logger.debug?

      unless @options[:pid_file].nil?
        if pid_file_valid?(@options[:pid_file])
          logger.error("pidfile #{@options[:pid_file]} refers to existing process #{pid.to_s}, refusing to overwrite")
          Kernel.exit(3)
        end
        begin
          File.open(@options[:pid_file], 'w') { |pid_file| pid_file.write("#{$$}\n") }
          logger.info("wrote process PID #{$$} to pidfile #{@options[:pid_file]}")
        rescue SystemCallError => e
          logger.error("could not write PID #{$$} to pidfile #{@options[:pid_file]}: #{e.to_s}")
          Kernel.exit(4)
        end
      end

      Dir.chdir('/')

      hook_privileged()
      unless @options[:user].nil?
        Process.initgroups(@options[:user][:name], @options[:user][:gid])
        Process::GID.change_privilege(@options[:user][:gid])
        Process::UID.change_privilege(@options[:user][:uid])
        ENV['HOME'] = @options[:user][:dir]
        ENV['USER'] = @options[:user][:name]
      end

      hook_pre_main()
      begin
        hook_main()
        for i in 1..(@options[:sleep] * 10)
          break unless hook_continue?()
          sleep(0.1)
        end
      end while hook_continue?()
      hook_post_main()
    end
  end
end

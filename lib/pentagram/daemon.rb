require 'etc'
require 'logger'
require 'optparse'
require 'pentagram/signal_broker'

module Pentagram
  class Daemon
    def initialize
      @@continue = true unless defined?(@@continue)
      if @logger.nil?
        self.logger = Logger.new($stdout)
        logger.level = Logger::INFO
      else
        self.logger = @logger
      end
      SignalBroker.register_brokers

      option_parser.separator("\nArguments:")

      option_parser.on('-?', '-h', '--help', 'show application usage information') do
        puts option_parser
        Kernel.exit(0)
      end

      options[:daemonize] = false unless options.include?(:daemonize)
      option_default = options[:daemonize] ? 'daemonize to background' : 'stay in the foreground'
      option_parser.on(
        '-d', '--daemonize',
        "daemonize to background (default: #{option_default})"
      ) do |b|
        options[:daemonize] = true
      end

      options[:once] = false unless options.include?(:once)
      option_default = options[:once] ? 'execute only once' : 'loop execution until interrupted'
      option_parser.on(
        '--once',
        "only execute the main program loop once, do not repeat (default: #{option_default})"
      ) do |b|
        options[:once] = true
      end

      options[:pid_file] ||= nil
      option_default = options[:pid_file] || 'no pidfile will be created'
      option_parser.on(
        '--pid-file FILE',
        "specify a pidfile that will be overwritten to contain the PID of this process (default: #{option_default})"
      ) do |s|
        options[:pid_file] = s
      end

      options[:sleep] ||= 0
      option_parser.on(
        '--sleep SECONDS', Float,
        "sleep this many seconds in-between main program loop runs (default: #{options[:sleep]}s)"
      ) do |f|
        raise OptionParser::InvalidArgument, "sleep time must be greater than or equal to zero" if f < 0
        options[:sleep] = f
      end

      options[:user] ||= nil
      option_default = options[:user] || 'do not drop privileges'
      option_parser.on(
        '--user USER',
        "drop privileges to user USER after initialization (default: #{option_default})"
      ) do |s|
        begin
          options[:user] = Etc.getpwnam(s)
        rescue ArgumentError => e
          raise OptionParser::InvalidArgument, "user must be a valid system user: #{e}"
        end
      end

      options[:verbose] = false unless options.include?(:verbose)
      option_default = options[:verbose] ? 'enabled' : 'disabled'
      option_parser.on(
        '-v', '--verbose',
        "enable verbose output (default: #{option_default})"
      ) do |b|
        options[:verbose] = true
      end

      option_parser.on('-V', '--version', 'display application version information') do
        puts option_parser.ver
        Kernel.exit(0)
      end
    end

    # We want to support any reasonably sane logging object (i.e., Logger or Log4r). These libraries usually have
    # constants that define logging levels (Logger::DEBUG, Log4r::INFO, etc.), but they sometimes keep those constants
    # at different places relative to the active logging object itself, so we can't hardcode the path to the constants
    # and expect it to work. We therefore attempt to cover the common cases by searching the module/class hierarchy for
    # the log-level constant that we're looking for. If we can't find the constant, we immediately raise an exception
    # so that the failure is clear.
    private def get_logger_level(level)
      level = level.to_sym
      const_hierarchy = logger.class.name.split('::')
      while const_hierarchy.length > 0
        const = Kernel.const_get(const_hierarchy.join('::'))
        return const.const_get(level) if const.const_defined?(level)
        const_hierarchy.pop
      end
      raise NameError.new("unable to find log-level constant #{level.inspect} within #{logger.class.name} hierarchy")
    end

    def hook_continue?
      # Handle any outstanding (queued) signals. By default we schedule an exit if there are any unhandled signals
      # that are found to be outstanding. If all of the outstanding signals have handlers, then we leave it to the
      # handlers to decide what to do and do not take any action.
      handled, unhandled = SignalBroker.handle_queued_signals
      @@continue = false if unhandled.length > 0
      return (@@continue && options[:once] == false)
    end

    def hook_pre_main; end

    def hook_main; end

    def hook_post_main; end

    def hook_privileged; end

    def next_sleep_time
      options[:sleep]
    end

    def logger
      @logger
    end

    def logger=(logger)
      @logger = logger
      SignalBroker.logger = @logger
    end

    def options
      @options ||= {}
    end

    def option_parser
      @option_parser ||= OptionParser.new
    end

    def parse_arguments!
      option_parser.parse!
    end

    private def pid_file_create(path)
      pid = pid_file_valid?(path)
      if pid
        logger.error("pidfile #{path} belongs to another valid process (#{pid}), refusing to overwrite it")
        Kernel.exit(3)
      end
      File.open(path, 'w') { |pid_file| pid_file.write("#{$$}\n") }
      logger.info("wrote process pid #{$$} to pidfile #{path}")
    rescue SystemCallError => e
      logger.error("could not write pid #{$$} to pidfile #{path}: #{e}")
      Kernel.exit(4)
    end

    private def pid_file_delete(path)
      pid = pid_file_valid?(path)
      if pid && pid != $$
        logger.warn("pidfile #{path} belongs to another valid process (#{pid}), refusing to delete it")
        return
      end
      File.delete(path)
    rescue SystemCallError => e
      logger.warn("pidfile #{path} could not be removed: #{e}")
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
        return pid
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
        parse_arguments!
      rescue OptionParser::InvalidOption, OptionParser::InvalidArgument, OptionParser::MissingArgument => e
        puts e
        puts
        puts option_parser
        Kernel.exit(2)
      end
      logger.level = get_logger_level(:DEBUG) if options[:verbose]
      options.each { |k,v| logger.debug("options[#{k}] = #{v}") } if logger.debug?

      if options[:daemonize]
        GC.start
        Kernel.exit(0) if not Process.fork.nil?

        Process.setsid
        Kernel.exit(0) if not Process.fork.nil?

        $stdin.reopen(File.open('/dev/null', 'r'))
        $stdout.reopen(File.open('/dev/null', 'w'))
        $stderr.reopen(File.open('/dev/null', 'w'))
      end
      Dir.chdir('/')
      pid_file_create(options[:pid_file]) unless options[:pid_file].nil?
      hook_privileged
      unless options[:user].nil?
        Process.initgroups(options[:user][:name], options[:user][:gid])
        Process::GID.change_privilege(options[:user][:gid])
        Process::UID.change_privilege(options[:user][:uid])
        ENV['HOME'] = options[:user][:dir]
        ENV['USER'] = options[:user][:name]
      end

      hook_pre_main
      begin
        hook_main
        for i in 1..(next_sleep_time * 10)
          break unless hook_continue?
          sleep(0.1)
        end
      end while hook_continue?
      hook_post_main

      pid_file_delete(options[:pid_file]) unless options[:pid_file].nil?
    end
  end
end

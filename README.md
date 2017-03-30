# Pentagram Daemonization Library

## Impetus

This repository contains 'pentagram', a simple daemonization/process management library used internally at Clio. Before
this library was written, the various contenders in the space were considered (i.e., [Daemons], [DaemonKit], [Dante]),
but were generally not suited very well for our particular use case. We were looking for a very light daemonization
library that was easy to understand and that took care of the core behaviour required by daemonization without getting
in the way. Generally, our requirements were:

1. easy to read and understand.
2. allows hooking into both argument parsing and all signals in a very straightforward way.
3. supports the usual 'standard' daemonization arguments out of the box, but provides the flexibility to raise an
   exception when an argument is missing (i.e., to raise an exception when an argument is missing), and doesn't add any
   unusual arguments that may not apply across all use cases.
4. by default, handles signals with the traditional UNIX semantics (i.e., if the application doesn't handle the signal
   explicitly, then the application is terminated when the signal is received).
5. allows dropping of privileges, but takes care of possibly-privileged operations (i.e., like pidfile handling) before
   the privileges are dropped.
6. when dropping privileges, as much of the environment as possible is updated to remain consistent (i.e.,
   `ENV['HOME']`, `ENV['USER']`).
7. closes the 'standard' streams automatically upon daemonization (STDERR, STDOUT, STDIN).
8. does _not_ close other FDs or streams automatically upon daemonization, since privileged ports might have to be
   opened before privileges are dropped.
9. hooks into logging (via a standard `Logger` class) that doesn't encourage use of stdout/stderr.
10. protects against multiple instances of the same daemon running by default (i.e., refuses to overwrite an existing,
    valid pidfile).

None of the contenders that we examined fulfilled all of our needs, although [Dante] came the closest.

## Hooks

Pentagram provides a variety of hooks that you can define in your child class, in order to execute code at specific
points in the daemonization process. None of these hooks are technically required, but you'll find that your daemon
will not achieve very much until you define at least `hook_main`.

For the two hooks that have code already defined (`parse_arguments!` and `hook_continue?`), be sure to call `super` in
your method body if you choose to override them.

| Hook               | Purpose                                                                                        |
| ------------------ | ---------------------------------------------------------------------------------------------- |
| `parse_arguments!` | Defined in Pentagram::Daemon, carries out parsing and validation of command-line arguments.    |
| `hook_continue?`   | Defined in Pentagram::Daemon, decides whether the daemon should continue after each iteration. |
| `hook_privileged`  | If defined, will be executed after daemonization but before user privileges are dropped.       |
| `hook_pre_main`    | If defined, will be executed just before the main iteration loop of the daemon is entered.     |
| `hook_main`        | If defined, will be executed once per daemon iteration - put your core work here.              |
| `hook_post_main`   | If defined, will be executed just after the main iteration loop of the daemon is exited.       |

## Signals

Pentagram automatically installs global handlers (traps) for all signals and provides a framework to easily register
signal handlers via `SignalBroker#register_broker(sig, handler)`. During default operations, received signals are
queued for dispatch and are actually handled during any call to `Daemon#hook_continue?`. As per traditional UNIX
semantics, received signals that do not have assigned handlers will cause the daemon to exit.

For a polling daemon, the above behaviour (combined with a fairly quick-to-execute main loop) should work fine. For a
daemon that is listening for data (for example, waiting for data to be available on some selection of file descriptors)
there is a convenience wrapper method (`SignalBroker.select`) that can be used in place of `IO.select` in order to
implement a highly efficient wait-for-input loop that also handles signals cleanly.

## Example Usage

```ruby
require 'fileutils'
require 'logger'
require 'pentagram'

class GoatHerderDaemon < Pentagram::Daemon
  def initialize
    # If our daemon wants to override any of the default settings that are in our parent class, we can do so here.
    options[:pid_file] ||= '/tmp/goat_herder.pid'
    options[:sleep] ||= 60
    # If we want to debug our initialization process, we can setup a debug logger here. If we don't set up a logger,
    # then one will be initialized for us (but it will be at the Logger::INFO level and thus will not contain
    # DEBUG log entries).
    self.logger = Logger.new($stdout)
    logger.level = Logger::DEBUG
    super

    Pentagram::SignalBroker.register_handler(:HUP, self.method(:signal_hup))

    option_parser.banner = "#{File.basename(__FILE__)} [options] /path/to/goat/paddock"
    option_parser.version = '6.6.6'

    options[:num_goats] ||= 12
    option_parser.on(
      '--num-goats GOATS', Integer,
      "the number of goats to monitor (default: #{options[:num_goats]})"
    ) do |i|
      raise OptionParser::InvalidArgument, "number of goats must be greater than zero" if i <= 0
      options[:num_goats] = i
    end
  end

  private def goat_path(i)
    File.join(ARGV[0], "goat-#{i}.txt")
  end

  def parse_arguments!
    super
    raise OptionParser::MissingArgument, "/path/to/goat/paddock was not given" unless ARGV.size > 0
  end

  def signal_hup(signal)
    FileUtils.touch("/tmp/GoatHerderDaemon.#{$$}.HUP")
  end

  def hook_privileged
    FileUtils.mkdir_p(ARGV[0])
    logger.info("created goat paddock #{ARGV[0]}")
  end

  def hook_main
    options[:num_goats].times do |i|
      FileUtils.touch(goat_path(i))
      logger.debug("woke up goat ##{i}")
    end
  end

  def hook_post_main
    FileUtils.rm_f("/tmp/GoatHerderDaemon.#{$$}.HUP")
    options[:num_goats].times do |i|
      if File.size(goat_path(i)) == 0
        File.unlink(goat_path(i))
        logger.debug("reaped goat ##{i}")
      else
        logger.error("unable to reap goat ##{i}, unexpected file size of #{File.size(goat_path(i))} bytes")
      end
    end
    begin
      Dir.rmdir(ARGV[0])
      logger.info("removed goat paddock #{ARGV[0]}")
    rescue SystemCallError => e
      logger.error("unable to remove goat paddock #{ARGV[0]}: #{e}")
    end
  end
end

GoatHerderDaemon.new.run
```

[Daemons]: https://github.com/thuehlinger/daemons
[DaemonKit]: https://github.com/kennethkalmer/daemon-kit
[Dante]: https://github.com/nesquena/dante

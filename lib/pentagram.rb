require 'pentagram/daemon'
require 'pentagram/version'

module Pentagram
  trap('HUP')  { Daemon.enqueue_signal(:HUP)  }
  trap('INT')  { Daemon.enqueue_signal(:INT)  }
  trap('TERM') { Daemon.enqueue_signal(:TERM) }
  trap('USR1') { Daemon.enqueue_signal(:USR1) }
  trap('USR2') { Daemon.enqueue_signal(:USR2) }
end

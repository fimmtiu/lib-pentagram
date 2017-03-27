$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))
require 'pentagram/version'

Gem::Specification.new do |spec|
  spec.authors     = ['Remi Broemeling']
  spec.description = <<-EOF
    Pentagram strives to be a very straightforward, flexible daemonization library for ruby. It specifically
    does not try to be all things to all people, but rather attempts to provide a minimalist framework on which
    arbitrary daemons can be built in a fairly standard way.
  EOF
  spec.email       = 'services@clio.com'
  spec.files       = Dir['lib/**/*.rb'] + Dir['spec/**/*.rb']
  spec.homepage    = 'https://github.com/clio/pentagram'
  spec.licenses    = ['BSD-3-Clause']
  spec.name        = File.basename(__FILE__, '.gemspec')
  spec.summary     = %q{A straightforward process daemonization library for ruby.}
  spec.version     = Pentagram::VERSION
end

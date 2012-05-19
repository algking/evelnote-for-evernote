# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "evelnote/version"

Gem::Specification.new do |s|
  s.name        = "evelnote"
  s.version     = Evelnote::VERSION
  s.authors     = ["f-kubotar"]
  s.email       = ["dev@hadashikick.jp"]
  s.homepage    = "http://github.com/f-kubotar/evernote.el"
  s.summary     = %q{Evernote client for Emacs}
  s.description = %q{Evernote client for Emacs}

  s.rubyforge_project = "evelnote"

  s.files         = `git ls-files`.split("\n") -
                    ['.gitignore', '.gitmodules', 'vendor/evernote-sdk-ruby'] +
    		    `cd vendor/evernote-sdk-ruby; git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib",
                     'vendor/evernote-sdk-ruby/lib',
                     'vendor/evernote-sdk-ruby/lib/Evernote/EDAM']

  s.add_runtime_dependency "thrift", ['~> 0.8']
  s.add_runtime_dependency "kramdown", ['~> 0.13']
  # s.add_runtime_dependency "oauth", ['~> 0.4.6']
end

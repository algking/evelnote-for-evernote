require 'kramdown'

require 'thrift' 
require 'Evernote/EDAM/user_store'
require 'Evernote/EDAM/user_store_constants'
require 'Evernote/EDAM/note_store'
require 'Evernote/EDAM/limits_constants'

require 'evelnote/version'
require 'evelnote/s_expression'
require 'evelnote/enml'
require 'evelnote/edam'

module Evelnote
  LOG = Logger.new(open(File.join(File.dirname(__FILE__), '../debug.log'), 'w'))
  LOG.level = Logger::INFO
end

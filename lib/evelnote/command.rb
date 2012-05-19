include Evelnote

edam = EDAM.new

def gets_ascii8bit
  line = gets
  LOG.debug(line)

  if line.respond_to? :force_encoding
    line.force_encoding('ASCII-8BIT') # Thrift側では、文字列をバイト列として扱う
  end
  line
end

OptionParser.new do |opt|
  opt.on("--debug") {
    LOG.level = Logger::DEBUG
  }

  [ ['u', 'username'],
    ['p', 'password'] ].each do |short, long|
    opt.on("-#{short}", "--#{long} #{long.upcase.gsub('-', '')}") do |arg|
      edam.send(:"#{long}=", arg)
    end
  end

  opt.parse!(ARGV)
end

edam.authenticate! do |error|
  if error
    puts false.to_sexp
    puts error.inspect
    exit
  end

  puts true.to_sexp

  loop do 
    case gets_ascii8bit.strip
    when /list\s+notebooks/
      puts edam.notebooks.to_sexp

    when /list\s+tags/
      puts edam.tags.to_sexp

    when /query\s+(.+)/
      puts edam.query($1).to_sexp

    when /get\s+default\s+notebook/
      puts edam.default_notebook.to_sexp

    when /get\s+note\s+([\w-]+)/
      puts edam.get_note($1, :with_content => true).to_sexp

    when /save\s+note/
      # Header
      options = {}
      while (line = gets_ascii8bit) != "\n"
        case line
        when /Notebook-Guid:\s*(.+)/i
          options[:notebook_guid] = $1
        when /Guid:\s*(.+)/i
          options[:guid] = $1
        when /Title:\s*(.+)/i
          options[:title] = $1
        when /Tag-Names:\s*(.+)/i
          options[:tag_names] = $1.split(',').map{|tag_name| tag_name.strip }
        when /Content-Type:\s*(.+)/i
          options[:content_type] = $1.downcase
        end
      end
      
      # Body
      content = ''
      while (line = gets_ascii8bit) && (line != ".\n")
        content << (line == '..' ? '.' : line)
      end

      content_html = 
        case options.delete(:content_type)
        when /Markdown/i
          Kramdown::Document.new(content, :auto_ids => false).to_html
        else
          "<pre>\n#{content}\n</pre>"
        end

      begin
        note = edam.save_note(content_html, options)
        note.instance_eval do 
          @content = nil
        end
        puts note.to_sexp
      rescue Evernote::EDAM::Error::EDAMUserException => e
        puts e.inspect
      end
    end
  end
end


module Evelnote
  module ENML
    class ENElement
      alias :to_enml :to_s
    end

    class ENNote < ENElement
      attr_reader :content, :elements

      def initialize(content)
        @content = content.
          sub(/^\s*<\?xml\s+?.+?\?>/, '').
          sub(/^\s*<\!DOCTYPE\s+?.+?>/, '').
          sub(/^<en-note.*?>/, '').
          sub(/<\/en-note>\s*$/, '')
        @elements = []
      end

      def <<(element)
        unless element.is_a?(ENElement)
          raise ArgumentError, 'invalid ENElement: #{element.inspect}'
        end
        @elements << element
      end

      def to_enml
        <<ENML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml.dtd">
<en-note>
#{@content}
</en-note>
ENML
      end
    end
  end

  def self.ENNote(content)
    ENML::ENNote.new(content)
  end
end

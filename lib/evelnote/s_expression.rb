class Object
  def to_sexp
    self
  end
end

class String
  def to_sexp
    '"' << gsub(/[^\\]"/, '\"') << '"'
  end

  def underscore
    acronym_regex = /url|edam/

    word = self.dup
    word.gsub!(/::/, '/')
    word.gsub!(/(?:([A-Za-z\d])|^)(#{acronym_regex})(?=\b|[^a-z])/) { "#{$1}#{$1 && '_'}#{$2.downcase}" }
    word.gsub!(/([A-Z\d]+)([A-Z][a-z])/,'\1_\2')
    word.gsub!(/([a-z\d])([A-Z])/,'\1_\2')
    word.tr!("-", "_")
    word.downcase!
    word
  end

  def dasherize
    underscore.gsub(/_/, '-')
  end
end

class TrueClass
  def to_sexp
    't'
  end
end

class FalseClass
  def to_sexp
    'nil'
  end
end

class NilClass
  def to_sexp
    'nil'
  end
end

class Symbol
  def to_sexp
    "'#{to_s.dasherize}"
  end
end

class Array
  def to_sexp
    '(list ' << map{|v| v.to_sexp }.join(' ')  << ')'
  end
end

module Evelnote
  module SExpressionize
    # S式に変換
    def to_sexp()
      fields = struct_fields.map{|key, hash|
        field_name  = hash[:name]
        field_value = send(field_name)
        if field_value.is_a?(String) && hash[:type] == Thrift::Types::STRING &&
            field_name.match(/Hash$/)
          field_value = field_value.unpack('H*').first
        end
        [field_name, field_value]
      }.reject{|field_name, field_value|
        field_value.nil?
      }.map{|field_name, field_value|
        ":#{field_name.dasherize} #{field_value.to_sexp}"
      }

      class_name_base = self.class.name[/::([^:]+?)$/, 1].sub(/NoteList/i, 'Notelist')
      struct_name = "evelnote-#{class_name_base.dasherize}"
      "(make-#{struct_name} #{fields.join(' ')})" 
    end
  end
end

[
  :Notebook, :Note, :Tag,
  :Resource, :NoteAttributes, :Data, :ResourceAttributes
].each do |struct_class_name|
  Evernote::EDAM::Type.const_get(struct_class_name).
    send(:include, Evelnote::SExpressionize)
end
Evernote::EDAM::NoteStore::NoteList.send(:include, Evelnote::SExpressionize)

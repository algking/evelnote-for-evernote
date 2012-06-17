module Evelnote
  class VersionCheckError < StandardError; end

  class EDAM
    CONSUMER_KEY       = 'hadashikick'
    CONSUMER_SECRET    = 'a8dd6da79fa8d5dc'
    URL_BASE           = 'https://www.evernote.com'
    USERSTORE_URL      = "#{URL_BASE}/edam/user"
    NOTESTORE_URL_BASE = "#{URL_BASE}/edam/note"
    
    attr_accessor :username, :password
    attr_reader :auth

    def initialize(*args)
      Evelnote.logger.info("test")
      options = args.last.is_a?(Hash) ? args.pop : {}
      @username = args.shift
      @password = args.shift
    end

    def authenticate!
      error = nil
      begin
        @auth = userstore.authenticate(username, password,
                                       CONSUMER_KEY, CONSUMER_SECRET)
      rescue => error
      end

      if block_given?
        yield error
      else
        raise error if error
      end
    end

    def notebooks(cache=true)
      @notebooks = nil unless cache
      @notebooks ||= notestore_send :listNotebooks, auth_token      
    end

    def default_notebook(cache=true)
      @default_notebook = nil unless cache
      @default_notebook ||=
        (@notebooks && @notebooks.detect{|notebook| notebook.defaultNotebook }) ||
        (notestore_send :getDefaultNotebook, auth_token)
    end

    def tags(cache=true)
      []
    end

    def query(q, options={})
      filter = Evernote::EDAM::NoteStore::NoteFilter.new
      filter.words = q
      notestore_send :findNotes, auth_token, filter, 0, 100
    end

    def get_note(guid, options={})
      note = notestore_send(:getNote, auth_token, guid,
                            options[:with_content],
                            options[:with_resources_data],
                            options[:with_resources_recognition],
                            options[:with_resources_alternate_data])
      if note.content
        content = Evelnote::ENML::ENNote.new(note.content).content
        note.content =
          Kramdown::Document.new(content,
                                 :input    => 'html',
                                 :auto_ids => false).to_kramdown
      end
      note
    end

    def save_note(content_html, options={})
      note =
        if guid = options[:guid]
          get_note(guid)
        else
          Evernote::EDAM::Type::Note.new
        end

      note.notebookGuid = (options[:notebook_guid] || note.notebookGuid ||
                           default_notebook.guid)
      note.title        = (options[:title] || note.title || '(untitled)')
      note.tagNames     = (options[:tag_names] || note.tagNames)
      note.content      = Evelnote::ENML::ENNote.new(content_html).to_enml
      
      notestore_send((note.active ? :updateNote : :createNote), auth_token, note)
    end

    private

    def userstore
      return @userstore if @userstore

      userstore_transport = Thrift::HTTPClientTransport.new(USERSTORE_URL)
      userstore_protocol  = Thrift::BinaryProtocol.new(userstore_transport)
      @userstore = Evernote::EDAM::UserStore::UserStore::Client.new(userstore_protocol)
      
      check_version_args = [
        "Emacs evernote.el (Call Ruby)",
        Evernote::EDAM::UserStore::EDAM_VERSION_MAJOR,
        Evernote::EDAM::UserStore::EDAM_VERSION_MINOR,
      ]
      version_ok = @userstore.checkVersion(*check_version_args)
      
      unless version_ok
        @logger.error("check version faild. :" << check_version_args.inspect)
        raise VersionCheckError
      end

      @userstore
    end

    def auth_token
      auth.authenticationToken
    end

    def notestore
      return @notestore if defined? @notestore

      notestore_url = File.join(NOTESTORE_URL_BASE, auth.user.shardId)
      notestore_transport = Thrift::HTTPClientTransport.new(notestore_url)
      notestore_protocol = Thrift::BinaryProtocol.new(notestore_transport)
      @notestore = Evernote::EDAM::NoteStore::NoteStore::Client.new(notestore_protocol)
    end
  end
  
  def notestore_send(method_name, *args)
    begin
      notestore.send(method_name, *args)
    rescue Evernote::EDAM::Error::EDAMUserException => e
      # タイムアウトかもしれないので一回だけつなぎ直す
      authenticate!
      notestore.send(method_name, *args)
    end
  end
end

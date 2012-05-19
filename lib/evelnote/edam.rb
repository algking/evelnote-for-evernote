module Evelnote
  class VersionCheckError < StandardError; end

  class EDAM
    OAUTH_CONSUMER_KEY    = 'hadashikick-8299'
    OAUTH_CONSUMER_SECRET = '44200b03af9678b4'
    
    attr_accessor :username, :password
    attr_reader :auth

    def initialize(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}

      @username = args.shift
      @password = args.shift

      # @host = 'sandbox.evernote.com'
      @host = (options.delete(:sandbox) ? 'sandbox' : 'www') << '.evernote.com'
      @request_token_url  = "https://#{@host}/oauth"
      @access_token_url   = "https://#{@host}/oauth"
      @authorization_url  = "https://#{@host}/OAuth.action"

      @user_store_url     = "https://#{@host}/edam/user"
      @notestore_url_base = "https://#{@host}/edam/note"

      @logger = Logger.new(File.join(File.dirname(__FILE__), '../api.log'))
    end

    def authenticate!
      error = nil
        consumer = OAuth::Consumer.new(OAUTH_CONSUMER_KEY, OAUTH_CONSUMER_SECRET,
                                       :site => @host,
                                       :request_token_path => '/oauth',
                                       :access_token_path  => '/oauth',
                                       :authorize_path     => '/OAuth.action')
        request_token = consumer.get_request_token
        puts request_token.authorize_url
    end

    def notebooks(cache=true)
      @notebooks = nil unless cache
      @notebooks ||= notestore.listNotebooks(auth_token)      
    end

    def default_notebook(cache=true)
      @default_notebook = nil unless cache
      @default_notebook ||=
        (@notebooks && @notebooks.detect{|notebook| notebook.defaultNotebook }) ||
        notestore.getDefaultNotebook(auth_token)
    end

    def tags(cache=true)
      []
    end

    def query(q, options={})
      filter = Evernote::EDAM::NoteStore::NoteFilter.new
      filter.words = q
      notestore.findNotes(auth_token, filter, 0, 100)
    end

    def get_note(guid, options={})
      note = notestore.getNote(auth_token, guid,
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
      
      notestore.send((note.active ? :updateNote : :createNote), auth_token, note)
    end

    private

    def userstore
      return @userstore if @userstore

      userstore_transport = Thrift::HTTPClientTransport.new(userstore_url)
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
      return @notestore if @notestore

      notestore_url = File.join(@notestore_url_base, auth.user.shardId)
      notestore_transport = Thrift::HTTPClientTransport.new(notestore_url)
      notestore_protocol = Thrift::BinaryProtocol.new(notestore_transport)
      @notestore = Evernote::EDAM::NoteStore::NoteStore::Client.new(notestore_protocol)
    end
  end

  def notestore_send(method_name, *args)
    
  end
end

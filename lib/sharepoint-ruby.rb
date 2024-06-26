require 'curb'
require 'json'
require 'sharepoint-errors'
require 'sharepoint-session'
require 'sharepoint-object'
require 'sharepoint-types'

module Sharepoint
  class Site
    attr_reader   :server_url
    attr_accessor :url, :protocol
    attr_accessor :session
    attr_accessor :name
    attr_accessor :verbose

    def initialize server_url, site_name, prefix: "sites"
      @server_url  = server_url
      @name        = site_name
      uri_prefix   = unless prefix.empty? then prefix + '/' else '' end
      @url         = "#{@server_url}/#{uri_prefix}#{@name}"
      @session     = Session.new self
      @web_context = nil
      @protocol    = 'https'
      @verbose     = false
    end

    def authentication_path
      "#{@protocol}://#{@server_url}/_forms/default.aspx?wa=wsignin1.0"
    end

    def api_path uri
      "#{@protocol}://#{@url}/_api/web/#{uri}"
    end

    def filter_path uri
      uri
    end

    def context_info
      query :get, ''
    end

    # Sharepoint uses 'X-RequestDigest' as a CSRF security-like.
    # The form_digest method acquires a token or uses a previously acquired
    # token if it is still supposed to be valid.
    def form_digest
      if @web_context.nil? or (not @web_context.is_up_to_date?)
        @getting_form_digest = true
        @web_context         = query :post, "#{@protocol}://#{@url}/_api/contextinfo"
        @getting_form_digest = false
      end
      @web_context.form_digest_value
    end

    def query method, uri, body = nil, skip_json=false, &block
      uri        = if uri =~ /^http/ then uri else api_path(uri) end
      arguments  = [ uri ]
      arguments << body if method != :get
      result = Curl::Easy.send "http_#{method}", *arguments do |curl|
        curl.headers["Cookie"]          = @session.cookie
        curl.headers["Accept"]          = "application/json;odata=verbose"
    		curl.headers["user-agent"]		  = "NONISV|arera|programmazione/1.0"
        if method != :get
          curl.headers["Content-Type"]    = curl.headers["Accept"]
          curl.headers["X-RequestDigest"] = form_digest unless @getting_form_digest == true
          curl.headers["Authorization"] = "Bearer " + form_digest unless @getting_form_digest == true
        end
        curl.verbose = @verbose
        @session.send :curl, curl unless not @session.methods.include? :curl
        block.call curl           unless block.nil?
      end
      if !(skip_json || (result.body_str.nil? || result.body_str.empty?))
        begin
          data = JSON.parse result.body_str
          raise Sharepoint::DataError.new data, uri, body unless data['error'].nil?
          make_object_from_response data
        rescue JSON::ParserError => e
          raise Sharepoint::RequestError.new("Exception with body=#{body}, e=#{e.inspect}, #{e.backtrace.inspect}, response=#{result.body_str}")
        end
      elsif result.status.to_i >= 400
        raise Sharepoint::RequestError.new("#{method.to_s.upcase} #{uri} responded with #{result.status}")
      else
        result.body_str
      end
    end

    def make_object_from_response data
      if data['d']['results'].nil?
        data['d'] = data['d'][data['d'].keys.first] if data['d']['__metadata'].nil?
        if not data['d'].nil?
          make_object_from_data data['d']
        else
          nil
        end
      else
        array = Array.new
        data['d']['results'].each do |result|
          array << (make_object_from_data result)
        end
        array
      end
    end

    # Uses sharepoint's __metadata field to solve which Ruby class to instantiate,
    # and return the corresponding Sharepoint::Object.
    def make_object_from_data data
      type_name  = data['__metadata']['type'].gsub(/^SP\./, '')
                                             .gsub(/^Collection\(Edm\.String\)/, 'CollectionString')
                                             .gsub(/^Collection\(Edm\.Int32\)/, 'CollectionInteger')
      type_parts = type_name.split '.'
      type_name  = type_parts.pop
      constant   = Sharepoint
      type_parts.each do |part| constant = constant.const_get(part, false) end

      if constant.const_defined? type_name
        klass = constant.const_get type_name rescue nil
        klass.new self, data
      else
        Sharepoint::GenericSharepointObject.new type_name, self, data
      end
    end
  end
end

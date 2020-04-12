# frozen_string_literal: true

# Spotify developer authorization guide:
#   https://developer.spotify.com/documentation/general/guides/authorization-guide/
# Spotify Web API reference:
#   https://developer.spotify.com/documentation/web-api/reference-beta/

require 'net/http'
require 'base64'
require 'json'
require 'time'

module NMFbot
  class InvalidResponse < RuntimeError
  end

  # This class authenticates to and interacts with the Spotify API
  class SpotifyScraper
    # @param client_id [String] Spotify client id
    # @param client_secret [String] Spotify client secret
    # @param redirect_uri [String]
    # @param scope [String] Spotify scope. See:
    #   https://developer.spotify.com/documentation/general/guides/authorization-guide/#list-of-scopes
    #   For the New Music Friday playlist, we just need `playlist-modify-public`
    def initialize(client_id:, client_secret:, redirect_uri: 'http://localhost/',
                   scope: 'playlist-modify-public')
      @client_id = client_id
      @client_secret = client_secret
      @redirect_uri = redirect_uri
      @scope = scope

      # Load token from file, if it exists, so we can skip the auth flow
      if File.exist?(TOKEN_FILE)
        f = File.open(TOKEN_FILE, 'r')
        @access_token = JSON.parse(f.read)
        f.close
      else
        # We need to have the user get an authorization code, and then request
        # an access token using that code.
        # Step 1 in authorization guide
        @authorization_code = request_authorization_code
        # Step 2 in authorization guide
        @access_token = request_access_token
      end
    end

    # Checks if access token is expired; if it is, refreshes it; otherwise
    # it it returns the original access token
    # @return [Hash<Spotify Access Token>]
    def access_token
      created = @access_token['created'].to_i
      now = Time.now.to_i
      expires = @access_token['expires_in'].to_i
      if now - created > expires
        @access_token = request_access_token(refresh: true)
      end
      @access_token['access_token']
    end

    # @param str [String] any string to "webify"
    # @return [String] the "webified" URL --- replaces : and / with CGI
    #   characters.
    def webify(str)
      str.gsub(':', '%3A').gsub('/', '%2F')
    end

    # Directs user to follow link to Spotify authentication;
    # collects redirected URL from user and extracts authentication code from
    # it.
    # Step 1 in the authorization guide.
    # @return [String] Spotify authentication code.
    def request_authorization_code
      url = "https://accounts.spotify.com/authorize?client_id=#{@client_id}&" \
            "response_type=code&redirect_uri=#{webify(@redirect_uri)}&" \
            "scope=#{@scope}"

      puts 'To authenticate to the Spotify API, open this URL, ' \
           'accept the terms, and then paste the URL you were redirected to:'
      puts url
      print 'URL you were redirected to: '
      gets.chomp.gsub("#{@redirect_uri}?code=", '')
    end

    # Request access and refresh tokens
    # Step 2 in auth flow
    # @param refresh [Boolean] true if request is to refresh an existing token
    # @return [Hash<Spotify Access Token>] - looks like this:
    #   {"access_token"=>"your token", "token_type"=>"Bearer",
    #    "expires_in"=>3600, "refresh_token"=>"your refresh token",
    #    "scope"=>"playlist-modify-public","created"=>"1586697428"}
    def request_access_token(refresh: false)
      uri = URI.parse('https://accounts.spotify.com/api/token')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      grant = Base64.strict_encode64("#{@client_id}:#{@client_secret}")
      header = { 'Authorization' => "Basic #{grant}" }
      request = Net::HTTP::Post.new(uri.request_uri, header)
      form_data = if refresh
                    {
                      'grant_type' => 'refresh_token',
                      'refresh_token' => @access_token['refresh_token']
                    }
                  else
                    {
                      'grant_type' => 'authorization_code',
                      'code' => @authorization_code,
                      'redirect_uri' => @redirect_uri
                    }
                  end

      request.set_form_data(form_data)

      response = http.request(request)
      unless response.code == '200'
        raise InvalidResponse,
              "#{response.code} #{response.body}"
      end

      token = JSON.parse(response.body)

      # Adding a `created` UNIX timestamp to determine when the token needs to
      # be refreshed.
      token['created'] = Time.now.to_i

      File.open(TOKEN_FILE, 'w') do |f|
        f.write(token.to_json)
      end

      token
    end

    # @param endpoint [String] Spotify API to GET
    # @return [Hash/Array] - the response body
    def get(endpoint, retries: 0)
      raise InvalidResponse, 'Too many retries' if retries > 3

      uri = URI(endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri)
      request['authorization'] = "Bearer #{access_token}"

      response = http.request(request)

      case response.code
      when '200', '201', '202', '204'
        JSON.parse(response.body)
      # Unauthorized; most likely access token is expired
      when '401'
        puts '401 Unauthorized. Refreshing access token...'
        @access_token = request_access_token(refresh: true)
        get(endpoint, retries: retries + 1)
      # Too many requests
      when '429'
        puts '429 Too Many Requests. Sleeping...'
        sleep response['Retry-After'].to_i
        get(endpoint, retries: retries + 1)
      else
        raise InvalidResponse,
              "#{response.code} #{response.body}"
      end
    end

    # @param endpoint [String] the Spotify API endpoint to POST
    # @param body [String] - hash.to_json
    # @return [Hash/Array] - POST response body
    def post(endpoint, body, retries: 0)
      uri = URI(endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      header = {
        'Authorization' => "Bearer #{access_token}",
        'Content-Type' => 'application/json'
      }

      request = Net::HTTP::Post.new(uri.request_uri, header)
      request.body = body

      response = http.request(request)

      case response.code
      when '200', '201', '202', '204'
        JSON.parse(response.body)
      # Unauthorized; most likely access token is expired
      when '401'
        puts '401 Unauthorized. Refreshing access token...'
        @access_token = request_access_token(refresh: true)
        post(endpoint, body, retries: retries + 1)
      # Too many requests
      when '429'
        puts '429 Too Many Requests. Sleeping...'
        sleep response['Retry-After'].to_i
        post(endpoint, body, retries: retries + 1)
      else
        raise InvalidResponse,
              "#{response.code} #{response.body}"
      end
    end
  end
end

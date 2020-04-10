# frozen_string_literal: true

require 'nmfbot/spotify'
require 'nmfbot/reddit'

# Namespace module for nmfbot gem functionality
module NMFbot
  VERSION = '0.1.0'

  # NMFbot class
  class NMFbot
    # @return [SpotifyScraper] authenticated SpotifyScraper object
    attr_reader :spotify

    # @return [Redd::Models::Session]
    attr_reader :reddit

    # @return [RedditScraper] authenticated RedditScraper object
    attr_reader :reddit_scraper

    # @param spotify_client_id [String]
    # @param spotify_client_secret [String]
    # @param reddit_client_id [String]
    # @param reddit_client_secret [String]
    # @param reddit_username [String]
    # @param reddit_password [String]
    def initialize(spotify_client_id:, spotify_client_secret:,
                   reddit_client_id:, reddit_client_secret:,
                   reddit_username:, reddit_password:,
                   debug: false)
      if debug
        puts "Spotify client id: #{spotify_client_id}"
        puts "Spotify client sercret: #{spotify_client_secret}"
        puts "Reddit client id: #{reddit_client_id}"
        puts "Reddit client secret: #{reddit_client_secret}"
        puts "Reddit username: #{reddit_username}"
        puts "Reddit password: #{reddit_password}"
      end

      puts 'Creating Spotify session.' if debug
      @spotify = SpotifyScraper.new(spotify_client_id, spotify_client_secret)

      # Create Redd session
      # TODO remove Redd dependency; write a simpler API wrapper
      puts 'Creating Reddit session.' if debug
      @reddit = Redd.it(
        user_agent: "Redd:nmfbot:v#{VERSION} by /u/#{reddit_username}",
        client_id: reddit_client_id,
        secret: reddit_client_secret,
        username: reddit_username,
        password: reddit_password
      )

      puts 'Creating RedditScraper.' if debug
      @reddit_scraper = RedditScraper.new(@reddit)
    end

    # @return [Array<Reddit Listing>] - this week's New Music Friday thread from
    #   /r/indieheads.
    def nmf_thread
      indieheads_subreddit_about = @reddit_scraper
                                   .get_endpoint('/r/indieheads/about')
      pattern = /https:\/\/www.reddit.com\/r\/indieheads\/comments\/[a-z]+\/new_music_friday_[a-z]+_[0-9]{1,2}[a-z]{1,2}_[0-9]{4}\//
      match = pattern.match(indieheads_subreddit_about['data']['description'])[0]
      @reddit_scraper.get_endpoint(match.gsub(/https:\/\/www\.reddit\.com/, ''))
    end

    # @param nmf_thread [Array<Reddit Listing>] - the listing for this week's NMF thread
    # @return [Array<{artist: artist_name, album: album_name}>]
    def new_releases(nmf_thread)
      post_body = nmf_thread[0]['data']['children'][0]['data']['selftext']
      pattern = /\*\*.+? - \[.+?\]/
      matches = post_body.scan(pattern)
      split = matches.map { |x| x.gsub(/(\*|\[|\])/, '').split(' - ') }
      split.map do |x|
        {
          # The Spotify search API can only handle ASCII characters
          artist: x[0].gsub(/[^[:ascii:]]/, ''),
          album: x[1].gsub(/[^[:ascii:]]/, '')
        }
      end
    end

    # @param nmfthread [Array<Reddit Listing>] - the listing for this week's NMF thread
    # @return [String] the title of the thread
    def title(nmf_thread)
      nmf_thread[0]['data']['children'][0]['data']['title']
    end

    # @return [String] Spotify user id 
    def spotify_user_id
      response = @spotify.get('https://api.spotify.com/v1/me')
      response['id']
    end

    # @param album [String] album title
    # @param artist [String] artist name
    # @return [Hash<Spotify Simplified Album Object>]
    #   https://developer.spotify.com/documentation/web-api/reference/object-model/#album-object-simplified
    def search_for_album(album:, artist:)
      query = "q=album:#{album} artist:#{artist}&type=album".gsub(' ', '+')
      url = "https://api.spotify.com/v1/search?#{query}"
      response = @spotify.get(url)
      response['albums']['items'].each do |result|
        if result['artists'][0]['name'].match?(/#{Regexp.quote(artist)}/i) &&
           result['name'].match?(/#{Regexp.quote(album)}/i)
          return result
        end
      end
      nil
    end

    # @param albums [Array<Spotify Simplified Album Objects>]
    # @return [Array<Spotify Album Objects>]
    #   https://developer.spotify.com/documentation/web-api/reference/object-model/#album-object-full
    def albums(albums)
      album_objects = []
      url = 'https://api.spotify.com/v1/albums'

      # Maximum 20 albums per request
      while albums.size > 20
        album_ids = albums.pop(20)
                          .map { |x| x['id'] }
                          .join(',')
        result = @spotify.get(url + "/?ids=#{album_ids}")['albums']
        album_objects += result
      end

      album_ids = albums.map { |x| x['id'] }.join(',')
      album_objects += @spotify.get(url + "/?ids=#{album_ids}")['albums']
      album_objects
    end

    # @param album [Hash<Spotify Album Object>]
    # @param quantity [Integer] find the #{quantity} most popular tracks from
    #   the album
    # @return [Array<Spotify Track Objects>]
    #   https://developer.spotify.com/documentation/web-api/reference/object-model/#track-object-full
    def find_most_popular_tracks(album, quantity: 2)
      track_ids = album['tracks']['items'].map { |x| x['id'] }.join(',')
      tracks = @spotify.get("https://api.spotify.com/v1/tracks/?ids=#{track_ids}")
      sorted = tracks['tracks'].sort { |a, b| a['popularity'] <=> b['popularity'] }.reverse
      sorted.take(quantity)
    end

    # @param name [String] the name of the playlist
    # @return [Hash<Spotify Playlist Object>]
    #  https://developer.spotify.com/documentation/web-api/reference/object-model/#playlist-object-full
    def create_playlist(name)
      body = {
        'name' => name,
        'description' => "The most popular tracks from this week's New Music Friday on /r/indieheads"
      }
      url = "https://api.spotify.com/v1/users/#{spotify_user_id}/playlists"

      @spotify.post(url, body.to_json)
    end

    # @param tracks [Array<Spotify Track Objects>]
    # @param playlist [Hash<Spotify Playlist Object>]
    # @return [Integer] HTTP response code
    def add_tracks_to_playlist(tracks, playlist)
      url = "https://api.spotify.com/v1/playlists/#{playlist['id']}/tracks"
      body = {}
      track_uris = tracks.map { |x| x['uri'] }

      while track_uris.size > 100
        body['uris'] = track_uris.pop(100)
        @spotify.post(url, body.to_json)
      end
      body['uris'] = track_uris
      @spotify.post(url, body.to_json)
    end
  end
end

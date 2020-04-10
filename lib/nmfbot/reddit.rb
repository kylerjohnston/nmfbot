# frozen_string_literal: true

require 'json'
require 'redd'

module NMFbot
  class RedditScraper
    # @param session [Redd::Models::Session] Redd session
    def initialize(session)
      @session = session
      @client = session.client
    end

    # @param endpoint [String] Reddit API endpoint to request
    def get_endpoint(endpoint)
      JSON.parse(@client.get("#{endpoint}").raw_body)
    end
  end
end

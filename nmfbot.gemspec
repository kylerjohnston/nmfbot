Gem::Specification.new do |s|
  s.name = 'nmfbot'
  s.version = '0.1.2'
  s.date = '2020-04-12'
  s.summary = 'nmfbot'
  s.description = 'Create Spotify playlists of the most popular tracks from ' \
                  "new albums listed on /r/indieheads' New Music Friday threads"
  s.authors = ['Kyle Johnston']
  s.files = [
    'lib/nmfbot.rb',
    'lib/nmfbot/spotify.rb',
    'lib/nmfbot/reddit.rb'
  ]
  s.executables << 'nmfbot'
  s.homepage = 'https://github.com/kylerjohnston/nmfbot'
  s.license = 'MIT'
end

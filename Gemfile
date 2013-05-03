source 'https://rubygems.org'

gem 'google-api-client'
gem 'twilio-ruby'
gem 'sinatra'
gem 'data_mapper'
gem 'rack-ssl-enforcer'
group :production do
    gem "pg"
    gem "dm-postgres-adapter"
end

group :development, :test do
    gem "sqlite3"
    gem "dm-sqlite-adapter"
end
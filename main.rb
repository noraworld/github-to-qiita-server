# frozen_string_literal: true

require 'bundler/setup'
require 'faraday'
require 'json'
require 'sinatra'
require 'sinatra/reloader'

Bundler.require
Dotenv.load

post '/payload' do
  JSON.parse(params['payload'])['commits'].each do |commit|
    commit['added'].each do |new_file|
      connection = Faraday.new('https://api.github.com')
      connection.headers['Accept'] = 'application/vnd.github.VERSION.raw'
      response = connection.get("/repos/#{ENV['GITHUB_REPOS']}/contents/#{new_file}")

      # replace this with process that publishes to Qiita
      puts response.body
    end
  end

  puts 'ok'
end

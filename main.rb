# frozen_string_literal: true

require 'sinatra'
require 'sinatra/reloader'
require 'json'

post '/payload' do
  push = JSON.parse(params[:payload])
  puts "I got some JSON: #{push.inspect}"
end

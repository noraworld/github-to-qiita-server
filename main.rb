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
    commit['modified'].each do |new_file_path|
      next unless ENV['INCLUDED_DIR']&.split(',')&.include?(File.dirname(new_file_path))

      connection = Faraday.new('https://api.github.com')
      connection.headers['Accept'] = 'application/vnd.github.VERSION.raw'
      response = connection.get("/repos/#{ENV['GITHUB_REPOS']}/contents/#{new_file_path}")

      yaml_description = ''
      yaml_to_be_trimmed = ''
      if response.body.lines(chomp: true).first == '---'
        response.body.each_line.with_index do |line, index|
          if index.zero?
            yaml_to_be_trimmed += line
            next
          end

          if line =~ /^---/
            yaml_to_be_trimmed += '---'
            break
          end

          yaml_description   += line
          yaml_to_be_trimmed += line
        end
      end

      content = response.body.gsub(/\A#{Regexp.escape(yaml_to_be_trimmed)}/, '').gsub(/\A\n+/, '')
      puts content
    end
  end

  puts 'ok'
end

# frozen_string_literal: true

require 'bundler/setup'
require 'faraday'
require 'json'
require 'sinatra'
require 'sinatra/reloader'
require 'yaml'

Bundler.require
Dotenv.load

class QiitaItemNotFoundError < StandardError; end

post '/payload' do
  JSON.parse(params['payload'])['commits'].each do |commit|
    commit['added'].each do |new_file_path|
      next unless ENV['INCLUDED_DIR']&.split(',')&.include?(File.dirname(new_file_path))

      content, description = retrieve_content_and_description(new_file_path)
      response_body = publish_to_qiita(content, YAML.safe_load(description), new_file_path, mode: :add)
      map_filepath_with_qiita_item_id(new_file_path, response_body['id'])
    end

    commit['modified'].each do |new_file_path|
      next unless ENV['INCLUDED_DIR']&.split(',')&.include?(File.dirname(new_file_path))

      content, description = retrieve_content_and_description(new_file_path)
      publish_to_qiita(content, YAML.safe_load(description), new_file_path, mode: :edit)
    end
  end

  puts 'ok'
end

def retrieve_content_and_description(new_file_path)
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
  [content, yaml_description]
end

def publish_to_qiita(content, description, new_file_path, mode: nil)
  raise ArgumentError, "Argument `mode' is not specified" if mode.nil?
  raise ArgumentError, "Argument `mode' must be :add or :edit" unless %i[add edit].include?(mode)

  tags = []
  description['topics'].each { |topic| tags.push("name": topic) }

  request_url = case mode
                when :add
                  '/api/v2/items'
                when :edit
                  "/api/v2/items/#{qiita_item_id(new_file_path)}"
                end
  request_body = case mode
                 when :add
                   {
                     body: content.force_encoding('UTF-8'),
                     coediting: false,
                     group_url_name: nil,
                     private: true,
                     tags: tags,
                     title: description['title'],
                     tweet: false # only mode :add
                   }.to_json
                 when :edit
                   {
                     body: content.force_encoding('UTF-8'),
                     coediting: false,
                     group_url_name: nil,
                     private: true,
                     tags: tags,
                     title: description['title']
                   }.to_json
                 end

  # TODO: write more smartly!
  case mode
  when :add
    connection = Faraday.new('https://qiita.com')
    response = connection.post do |request|
      request.url(request_url)
      request.headers['Authorization'] = "Bearer #{ENV['QIITA_ACCESS_TOKEN']}"
      request.headers['Content-Type']  = 'application/json'
      request.body = request_body
    end
  when :edit
    connection = Faraday.new('https://qiita.com')
    response = connection.patch do |request|
      request.url(request_url)
      request.headers['Authorization'] = "Bearer #{ENV['QIITA_ACCESS_TOKEN']}"
      request.headers['Content-Type']  = 'application/json'
      request.body = request_body
    end
  end

  JSON.parse(response.body)
end

def map_filepath_with_qiita_item_id(filepath, item_id)
  File.open('mapping.txt', 'a') do |file|
    file.write("#{filepath}, #{item_id}\n")
  end
end

def qiita_item_id(filepath)
  File.open('mapping.txt', 'r') do |file|
    file.each_line do |line|
      return line.split(',').last.gsub(/[\s\r\n]/, '') if line.include?(filepath)
    end
  end

  raise QiitaItemNotFoundError, 'Qiita item not found'
end

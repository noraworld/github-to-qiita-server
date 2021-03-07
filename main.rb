# frozen_string_literal: true

require 'base64'
require 'bundler/setup'
require 'faraday'
require 'json'
require 'logger'
require 'pry'
require 'sinatra'
require 'sinatra/reloader' if settings.development?
require 'yaml'

Bundler.require
Dotenv.load

class QiitaItemNotFoundError < StandardError; end
class CannotGetGitHubContentError < StandardError; end

post '/payload' do
  verify_signature(request.body.read)

  if !JSON.parse(params['payload'])['commits'] && JSON.parse(params['payload'])['zen']
    log.debug('GitHub Webhook successfully added!')
    log.debug("GitHub zen: #{JSON.parse(params['payload'])['zen']}")
    return
  end

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

  # TODO: implement deletion?

  status 200
end

def retrieve_content_and_description(new_file_path)
  connection = Faraday.new('https://api.github.com')
  connection.headers['Accept'] = 'application/vnd.github.VERSION.raw'
  connection.headers['Authorization'] = "token #{ENV['GITHUB_PERSONAL_ACCESS_TOKEN']}"
  response = connection.get("/repos/#{ENV['GITHUB_REPOS']}/contents/#{new_file_path}")

  unless response.status.to_s[0] == '2'
    log.fatal("GitHub server returns status #{response.status}")
    log.fatal("Reason: #{response.body}")
    raise CannotGetGitHubContentError, "GitHub server returns status #{response.status}"
  end

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
  if mode.nil?
    log.fatal("Argument `mode' is not specified")
    raise ArgumentError, "Argument `mode' is not specified"
  end

  unless %i[add edit].include?(mode)
    log.fatal("Argument `mode' must be :add or :edit")
    raise ArgumentError, "Argument `mode' must be :add or :edit"
  end

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
                     private: private?(published: description['published']),
                     tags: tags,
                     title: description['title'],
                     tweet: !private?(published: description['published']) # only mode :add
                   }.to_json
                 when :edit
                   {
                     body: content.force_encoding('UTF-8'),
                     coediting: false,
                     group_url_name: nil,
                     private: private?(published: description['published']),
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

    log.debug('Published article(s) to Qiita successfully!')
    log.debug("Qiita item id: #{JSON.parse(response.body)['id']}")
  when :edit
    connection = Faraday.new('https://qiita.com')
    response = connection.patch do |request|
      request.url(request_url)
      request.headers['Authorization'] = "Bearer #{ENV['QIITA_ACCESS_TOKEN']}"
      request.headers['Content-Type']  = 'application/json'
      request.body = request_body
    end

    log.debug('Modified article(s) on Qiita successfully!')
    log.debug("Qiita item id: #{JSON.parse(response.body)['id']}")
  end

  JSON.parse(response.body)
end

def private?(published: false)
  return true if settings.development?

  !published
end

# Returns Hash
# {
#   content: String or Nil: the content of file decoded Base64,
#   sha: String or Nil: the SHA of file,
#   exist: Boolean: if mapping file exists
# }
def retrieve_mapping_file
  connection = Faraday.new('https://api.github.com')
  connection.headers['Accept'] = 'application/vnd.github.v3+json'
  connection.headers['Authorization'] = "token #{ENV['GITHUB_PERSONAL_ACCESS_TOKEN']}"
  response = connection.get("/repos/#{ENV['GITHUB_REPOS']}/contents/#{ENV['MAPPING_FILEPATH']}")

  mapping_file = if response.status == 404
                   {
                     content: nil,
                     sha: nil,
                     exist: false
                   }
                 else
                   {
                     content: Base64.decode64(JSON.parse(response.body)['content']),
                     sha: JSON.parse(response.body)['sha'],
                     exist: true
                   }
                 end

  # GitHub will return response status 404 if a mapping file does not exist
  # In that case, it will add a mapping file as a new file
  # This will probably happen only the first time
  if response.status.to_s[0] != '2' && response.status != 404
    log.fatal("GitHub server returns status #{response.status}")
    log.fatal("Reason: #{response.body}")
    raise CannotGetGitHubContentError, "GitHub server returns status #{response.status}"
  end

  mapping_file
end

def map_filepath_with_qiita_item_id(filepath, item_id)
  mapping_file = retrieve_mapping_file

  connection = Faraday.new('https://api.github.com')
  response = connection.put do |request|
    request.url("/repos/#{ENV['GITHUB_REPOS']}/contents/#{ENV['MAPPING_FILEPATH']}")
    request.headers['Accept'] = 'application/vnd.github.v3+json'
    request.headers['Authorization'] = "token #{ENV['GITHUB_PERSONAL_ACCESS_TOKEN']}"
    request.headers['Content-Type'] = 'application/json'

    request_body = {
      message: 'Update mapping file',
      content: Base64.encode64("#{filepath}, #{item_id}\n#{mapping_file[:content]}")
    }
    request_body.merge!(sha: mapping_file[:sha]) if mapping_file[:sha]
    request.body = request_body.to_json
  end

  return if response.status.to_s[0] == '2'

  log.fatal("GitHub server returns status #{response.status}")
  log.fatal("Reason: #{response.body}")
  raise CannotGetGitHubContentError, "GitHub server returns status #{response.status}"
end

def qiita_item_id(filepath)
  retrieve_mapping_file[:content]&.each_line do |line|
    return line.split(',').last.gsub(/[\s\r\n]/, '') if line.include?(filepath)
  end

  log.fatal('Qiita item not found')
  log.fatal(filepath)
  raise QiitaItemNotFoundError, 'Qiita item not found'
end

def verify_signature(payload_body)
  signature = "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), ENV['GITHUB_WEBHOOK_SECRET_TOKEN'], payload_body)}"
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE_256'])
end

def log
  FileUtils.mkdir_p('logs') unless FileTest.exist?('logs')
  Logger.new('logs/error.log', 'monthly')
end

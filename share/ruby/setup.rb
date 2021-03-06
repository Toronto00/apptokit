# frozen_string_literal: true

require 'pathname'
require 'openssl'
require 'yaml'
require 'uri'

module Apptokit
  VERSION = '0.1.0'

  class ApptokitError < RuntimeError
    attr_reader :type

    def initialize(msg, type: nil)
      @type = type
      super(msg)
    end
  end

  class Configuration
    HOME_DIR_CONF_PATH = Pathname.new(ENV["HOME"]).join(".config/apptokit.yml")
    HOME_DIR_CONF_DIR = Pathname.new(ENV["HOME"]).join(".config/apptokit")
    PROJECT_DIR_CONF_PATH = Pathname.new(Dir.pwd).join(".apptokit.yml")
    SHARE_DIR = Pathname.new(__FILE__).dirname.dirname

    YAML_OPTS = %w(
      private_key_path
      private_key_path_glob
      app_id
      webhook_secret
      installation_id
      github_url
      github_api_url

      client_id
      client_secret
      oauth_callback_port
      oauth_callback_bind
      oauth_callback_path
      oauth_callback_hostname

      installation_keycache_expiry
      user_keycache_expiry

      personal_access_token

      manifest_url
      manifest
      app_owner

      user_agent
      cookie
      accept_header
    ).freeze

    DEFAULT_GITHUB_URL     = URI("https://github.com")
    DEFAULT_GITHUB_API_URL = URI("https://api.github.com")

    attr_accessor :app_id, :webhook_secret, :installation_id
    attr_accessor :client_id, :client_secret, :oauth_callback_port, :oauth_callback_bind, :oauth_callback_path, :oauth_callback_hostname
    attr_accessor :personal_access_token
    attr_accessor :manifest_url, :manifest, :app_owner
    attr_accessor :cookie
    attr_writer :user_agent, :accept_header
    attr_writer :private_key_path_glob, :keycache_file_path, :env, :user_keycache_expiry, :installation_keycache_expiry, :private_key

    def self.environments
      envs = []
      [HOME_DIR_CONF_PATH, PROJECT_DIR_CONF_PATH].each do |path|
        envs += (YAML.load_file(path).keys - YAML_OPTS) if path.exist?
      end
      (envs - %w(default_env)).reject { |e| /_defaults/.match?(e) }
    end

    def self.loading_manifest(&block)
      if block
        @loading_manifest = true
        block.call
        @loading_manifest = false
      else
        @loading_manifest ||= nil
      end
    end

    def initialize(env = nil)
      @env = env
      reload!
    end

    def reload!
      set_opts_from_yaml(HOME_DIR_CONF_PATH)
      set_opts_from_yaml(PROJECT_DIR_CONF_PATH)
      set_opts_from_env
      set_opts_from_manifest
    end

    def private_key
      @private_key ||= begin
        raise ApptokitError, "Private key path not set but required for using a private key." unless private_key_path && !private_key_path.to_s.empty?

        OpenSSL::PKey::RSA.new(File.read(private_key_path))
      end
    end

    def private_key_path=(path)
      @private_key_path = Pathname.new(path)
    end

    def private_key_path
      @private_key_path ||= Dir[private_key_path_glob].max
    end

    def private_key_path_glob
      @private_key_path_glob ||= Pathname.new(Dir.pwd).join("*.pem")
    end

    def github_url=(arg)
      arg = arg[0..-2] if arg[-1] == "/"
      @github_url = URI(arg)
    end

    def github_url
      @github_url ||= DEFAULT_GITHUB_URL
    end

    def github_api_url=(arg)
      arg = arg[0..-2] if arg[-1] == "/"
      @github_api_url = URI(arg)
    end

    def github_api_url
      @github_api_url ||= DEFAULT_GITHUB_API_URL
    end

    def env
      @env ||= ENV["APPTOKIT_ENV"] || ENV["GH_ENV"]
    end

    def user_keycache_expiry
      @user_keycache_expiry ||= 5 * 24 * 60 * 60
    end

    def installation_keycache_expiry
      @installation_keycache_expiry ||= 9 * 60
    end

    def keycache_file_path
      @keycache_file_path ||= HOME_DIR_CONF_DIR.join(".apptokit_#{env || 'global'}_keycache")
    end

    def user_agent
      @user_agent ||= ENV["USER_AGENT"] || "Apptokit #{VERSION}"
    end

    def accept_header
      @accept_header ||= "application/vnd.github.v3.text-match+json"
    end

    def env_from_manifest?
      !manifest_url.nil? || !manifest.nil?
    end

    def clear_manifest_cache!
      manifest_settings.delete_cache
    end

    def debug(msg = nil, &block)
      return unless debug?
      return block.call if block

      $stderr.puts msg
    end

    private

    def set_opts_from_hash(hash)
      YAML_OPTS.each do |opt|
        if (value = hash[opt])
          send(:"#{opt}=", value)
        end
      end
    end

    def set_opts_from_yaml(path)
      return unless path.exist?

      yaml = YAML.safe_load(path.read, aliases: true)
      set_opts_from_hash(yaml)

      @env = yaml["default_env"] unless env

      return unless env

      env_overrides = yaml[env]
      set_opts_from_hash(env_overrides) if env_overrides
    end

    def set_opts_from_env
      set_opts_from_hash(YAML_OPTS.each_with_object({}) do |opt, out|
        out[opt] = ENV["APPTOKIT_#{opt.upcase}"]
      end)
    end

    def set_opts_from_manifest
      return if self.class.loading_manifest
      return unless env_from_manifest?

      if !manifest_settings.loaded? && realize_manifest?
        self.class.loading_manifest do
          manifest_settings.fetch
          manifest_settings.apply(Apptokit.config)
          manifest_settings.apply(self)
        end
      end

      if manifest_settings.loaded?
        self.class.loading_manifest do
          manifest_settings.apply(Apptokit.config)
          manifest_settings.apply(self)
        end
      end

      return unless installation_id.nil? && !installing_app?

      manifest_settings.install_app

      self.class.loading_manifest do
        manifest_settings.apply(Apptokit.config)
        manifest_settings.apply(self)
      end
    end

    def manifest_settings
      @manifest_settings ||= ManifestApp::Settings.new(
        env,
        { "manifest_url" => manifest_url, "manifest" => manifest },
        app_owner
      )
    end

    def realize_manifest?
      !ENV.key?("LIMITED_MANIFEST")
    end

    def installing_app?
      ENV.key?("INSTALLING_APP")
    end

    def debug?
      ENV.key?("DEBUG")
    end
  end

  module_function

  def config
    return @config if defined?(@config) && !block_given?

    @config = Configuration.new

    yield @config if block_given?

    @config
  end
end

require 'apptokit/manifest_app/settings'

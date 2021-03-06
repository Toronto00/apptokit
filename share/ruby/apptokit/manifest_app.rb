# frozen_string_literal: true

require 'net/http'
require 'erb'
require 'tempfile'

require 'apptokit/jwt'
require 'apptokit/callback_server'

module Apptokit
  class ManifestApp
    FORM_TEMPLATE = ERB.new(
      Configuration::SHARE_DIR.join("create_manifest_app.html.erb").read
    )

    attr_reader :env_name, :yaml_conf, :app_owner, :mutex, :condition_variable, :auto_open, :code, :skip_cache
    attr_writer :code
    private :code=

    def initialize(env_name:, yaml_conf:, app_owner:, auto_open: nil, code: nil, skip_cache: false)
      @env_name = env_name
      @yaml_conf = yaml_conf
      @app_owner = app_owner
      @auto_open = auto_open.nil? ? true : auto_open
      @code = code
      @cached = true
      @skip_cache = skip_cache
      @mutex, @condition_variable = Mutex.new, ConditionVariable.new
      @github_settings_response = nil
    end

    def create_app
      walk_user_through_creation_flow unless code
      @github_settings_response = exchange_code_for_app_settings
    end

    def walk_user_through_creation_flow
      tempfile = Tempfile.new(["app_manifest", ".html"])
      tempfile.write(FORM_TEMPLATE.result(binding))
      tempfile.flush

      callback_server = CallbackServer.new(mutex, condition_variable, response: :manifest) do |server|
        server.port = 8875
        server.path = "/manifest_callback"
      end
      callback_server.start

      if auto_open
        `$BROWSER #{tempfile.path}`
      else
        puts "Please open the link below to continue creating the application:\n\n  file://#{tempfile.path}\n\n"
      end

      mutex.synchronize { condition_variable.wait(mutex, 60) }
      callback_server.shutdown

      if callback_server.killed?
        $stderr.puts "Aborting manifest setup process, the App will not be created."
        exit
      end

      unless callback_server.code
        raise ApptokitError.new(
          "Failed to get an manifest creation code from GitHub, did you visit the URL in your browser?",
          type: :manifest_creation_failed
        )
      end

      self.code = callback_server.code
    ensure
      if tempfile
        tempfile.close
        tempfile.unlink
      end
    end

    def exchange_code_for_app_settings
      uri = URI("#{Apptokit.config.github_api_url}/app-manifests/#{code}/conversions")
      res = Net::HTTP.post(uri, "", { "Accept" => "application/vnd.github.fury-preview+json" })

      case res
      when Net::HTTPSuccess
        JSON.parse(res.body)
      else
        raise ApptokitError, "Failed to exchange GitHub App Manifest code for App credentials: #{res.code}\n\n#{res.body}"
      end
    end

    def manifest_json
      JSON.pretty_generate({
        name: yaml_manifest["name"] || generated_name,
        url: yaml_manifest["url"] || "http://example.com",
        hook_attributes: yaml_manifest["hook_attributes"] || { url: "http://example.com/webhooks" },
        callback_url: yaml_manifest["callback_url"] || "http://localhost:8075/callback",
        redirect_url: callback_server_url,
        description: yaml_manifest["description"] || "An Apptokit Managed GitHub App",
        public: yaml_manifest["public"] || false,
        default_events: yaml_manifest["events"],
        default_permissions: yaml_manifest["permissions"]
      })
    end

    def generated_name
      "#{env_name} Manifested App"
    end

    def callback_server_url
      "http://localhost:8875/manifest_callback"
    end

    def yaml_manifest
      yaml_conf["manifest"] = fetch_manifest_from_url if yaml_conf["manifest_url"]
      yaml_conf["manifest"]
    end

    def manifest_flow_start_url
      owner_part = app_owner ? "/organizations/#{app_owner}" : ""
      "#{Apptokit.config.github_url}#{owner_part}/settings/apps/new"
    end

    def fetch_manifest_from_url
      res = Net::HTTP.get(URI(yaml_conf["manifest_url"]))

      case res
      when Net::HTTPSuccess
        JSON.parse(res.body)
      else
        $stderr.puts "Could not fetch an App Manifest from #{yaml_conf['manifest_url']}"
        exit 20
      end
    end
  end
end

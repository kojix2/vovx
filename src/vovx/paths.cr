module VOVX
  module Paths
    APP_DIR_NAME = "vovx"

    def self.executable_dir : String
      Process.executable_path.try { |path| File.dirname(path) } || Dir.current
    end

    def self.home_dir : String
      ENV["HOME"]? || Dir.current
    end

    def self.config_dir : String
      {% if flag?(:darwin) %}
        File.join(home_dir, "Library", "Application Support", APP_DIR_NAME)
      {% else %}
        if xdg_config_home = ENV["XDG_CONFIG_HOME"]?
          return File.join(xdg_config_home, APP_DIR_NAME) unless xdg_config_home.empty?
        end

        File.join(home_dir, ".config", APP_DIR_NAME)
      {% end %}
    end

    def self.settings_path : String
      if path = ENV["VOVX_CONFIG"]?
        return path unless path.empty?
      end

      File.join(config_dir, "config.json")
    end

    def self.log_dir : String
      {% if flag?(:darwin) %}
        File.join(home_dir, "Library", "Logs", APP_DIR_NAME)
      {% else %}
        if xdg_state_home = ENV["XDG_STATE_HOME"]?
          return File.join(xdg_state_home, APP_DIR_NAME) unless xdg_state_home.empty?
        end

        File.join(home_dir, ".local", "state", APP_DIR_NAME)
      {% end %}
    end

    def self.log_path : String
      if path = ENV["VOVX_LOG"]?
        return path unless path.empty?
      end

      File.join(log_dir, "vovx.log")
    end

    def self.bundled_resource_path(*parts : String) : String
      File.expand_path(File.join("..", "Resources", *parts), executable_dir)
    end

    def self.development_resource_path(*parts : String) : String
      File.join(Dir.current, "resources", *parts)
    end

    def self.macos_services_dir : String
      File.join(home_dir, "Library", "Services")
    end
  end
end

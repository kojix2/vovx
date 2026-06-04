require "json"

module VOVX
  struct UserSettings
    getter speaker_id : Int32?
    getter rate : Float64?

    def initialize(@speaker_id : Int32? = nil, @rate : Float64? = nil)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "speaker_id", speaker_id
        json.field "rate", rate
      end
    end
  end

  def self.settings_path : String
    if path = ENV["VOVX_CONFIG"]?
      return path unless path.empty?
    end

    File.join(settings_dir, "config.json")
  end

  def self.settings_dir : String
    home = ENV["HOME"]? || Dir.current

    {% if flag?(:darwin) %}
      File.join(home, "Library", "Application Support", "vovx")
    {% else %}
      if xdg_config_home = ENV["XDG_CONFIG_HOME"]?
        return File.join(xdg_config_home, "vovx") unless xdg_config_home.empty?
      end

      File.join(home, ".config", "vovx")
    {% end %}
  end

  def self.load_user_settings(path : String = settings_path) : UserSettings
    return UserSettings.new unless File.exists?(path)

    json = JSON.parse(File.read(path)).as_h
    UserSettings.new(
      speaker_id: json["speaker_id"]?.try(&.as_i?),
      rate: normalize_rate(json["rate"]?.try(&.as_f?))
    )
  rescue ex
    log_event("settings.load_failed path=#{path} message=#{ex.message}")
    UserSettings.new
  end

  def self.save_user_settings(settings : UserSettings, path : String = settings_path) : Nil
    Dir.mkdir_p(File.dirname(path))
    File.write(path, settings.to_json)
    log_event("settings.saved path=#{path}")
  rescue ex
    log_event("settings.save_failed path=#{path} message=#{ex.message}")
  end

  private def self.normalize_rate(rate : Float64?) : Float64?
    rate.try { |value| value.clamp(0.5, 2.0) }
  end
end

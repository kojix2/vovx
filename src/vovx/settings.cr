require "json"

module VOVX
  struct UserSettings
    getter speaker_id : Int32?
    getter rate : Float64?
    getter? auto_play : Bool
    getter? quit_after_playback : Bool

    def initialize(@speaker_id : Int32? = nil, @rate : Float64? = nil, @auto_play : Bool = false, @quit_after_playback : Bool = true)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "speaker_id", speaker_id
        json.field "rate", rate
        json.field "auto_play", auto_play?
        json.field "quit_after_playback", quit_after_playback?
      end
    end
  end

  def self.settings_path : String
    Paths.settings_path
  end

  def self.settings_dir : String
    Paths.config_dir
  end

  def self.load_user_settings(path : String = settings_path) : UserSettings
    return UserSettings.new unless File.exists?(path)

    json = JSON.parse(File.read(path)).as_h
    UserSettings.new(
      speaker_id: json["speaker_id"]?.try(&.as_i?),
      rate: normalize_rate(json["rate"]?.try(&.as_f?)),
      auto_play: json_bool(json, "auto_play", false),
      quit_after_playback: json_bool(json, "quit_after_playback", true)
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
    rate.try(&.clamp(0.5, 2.0))
  end

  private def self.json_bool(json : Hash(String, JSON::Any), key : String, default : Bool) : Bool
    value = json[key]?.try(&.as_bool?)
    value.nil? ? default : value
  end
end

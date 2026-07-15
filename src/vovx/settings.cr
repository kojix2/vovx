require "json"

module VOVX
  struct UserSettings
    include JSON::Serializable

    getter speaker_id : Int32?
    getter rate : Float64?
    getter? auto_play : Bool = false
    getter? quit_after_playback : Bool = true

    def initialize(@speaker_id : Int32? = nil, @rate : Float64? = nil, @auto_play : Bool = false, @quit_after_playback : Bool = true)
      after_initialize
    end

    def after_initialize
      @rate = VOVX.normalize_rate(@rate)
    end
  end

  def self.settings_path : String
    Paths.settings_path
  end

  def self.load_user_settings(path : String = settings_path) : UserSettings
    return UserSettings.new unless File.exists?(path)

    UserSettings.from_json(File.read(path))
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

  protected def self.normalize_rate(rate : Float64?) : Float64?
    rate.try(&.clamp(0.5, 2.0))
  end
end

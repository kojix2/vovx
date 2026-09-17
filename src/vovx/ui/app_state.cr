require "uing"

module VOVX
  private class AppState
    property sentences : Array(String)
    property styles : Array(VoiceStyleOption)
    property selected_speaker : Int32
    property slider_percent : Int32
    property? audio_ready = false
    property? voicevox_ready = false
    property? auto_play : Bool
    property? auto_play_started = false
    property? quit_after_playback : Bool
    property preferred_speaker : Int32?
    property settings_window : UIng::Window? = nil
    property? closing = false
    getter startup_cancellation = CancellationToken.new
    @startup_mutex = Mutex.new
    @startup_running = false

    def initialize(@sentences : Array(String), @styles : Array(VoiceStyleOption), default_rate : Float64, settings : UserSettings)
      @styles = [VOVX.default_voice_style] if @styles.empty?
      @preferred_speaker = settings.speaker_id
      @selected_speaker = settings.speaker_id || @styles.first.speaker_id
      @slider_percent = ((settings.rate || default_rate) * 100).round.to_i.clamp(50, 200)
      @auto_play = settings.auto_play?
      @quit_after_playback = settings.quit_after_playback?
    end

    def startup_running? : Bool
      @startup_mutex.synchronize { @startup_running }
    end

    def startup_running=(running : Bool) : Nil
      @startup_mutex.synchronize { @startup_running = running }
    end

    def rate : Float64
      slider_percent / 100.0
    end

    def to_user_settings : UserSettings
      UserSettings.new(
        speaker_id: selected_speaker,
        rate: rate,
        auto_play: auto_play?,
        quit_after_playback: quit_after_playback?
      )
    end
  end

  private record AppControls,
    window : UIng::Window,
    voice_combobox : UIng::Combobox,
    speed_slider : UIng::Slider,
    speed_label : UIng::Label,
    status_label : UIng::Label,
    play_button : UIng::Button,
    stop_button : UIng::Button
end

require "uing"

module VOVX
  private def self.show_settings_window(state : AppState) : Nil
    if window = state.settings_window
      window.show unless window.released?
      return
    end

    window = UIng::Window.new("設定", 360, 130, margined: true)
    window.resizeable = false
    state.settings_window = window

    root = UIng::Box.new(:vertical, padded: true)

    auto_play_checkbox = UIng::Checkbox.new("自動的に再生する")
    auto_play_checkbox.checked = state.auto_play?
    auto_play_checkbox.on_toggled do |checked|
      state.auto_play = checked
      save_user_settings(state.to_user_settings)
    end
    root.append(auto_play_checkbox)

    quit_after_playback_checkbox = UIng::Checkbox.new("再生が終わったら終了する")
    quit_after_playback_checkbox.checked = state.quit_after_playback?
    quit_after_playback_checkbox.on_toggled do |checked|
      state.quit_after_playback = checked
      save_user_settings(state.to_user_settings)
    end
    root.append(quit_after_playback_checkbox)

    window.child = root
    window.on_closing do
      save_user_settings(state.to_user_settings)
      state.settings_window = nil
      true
    end
    center_window_on_main_screen(window, 360, 130)
    window.show
  end

  private def self.close_settings_window(state : AppState) : Nil
    window = state.settings_window
    return if window.nil?

    state.settings_window = nil
    window.destroy unless window.released?
  rescue ex
    log_event("ui.settings_window_close_failed message=#{ex.message}")
  end
end

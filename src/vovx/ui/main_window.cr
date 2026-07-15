require "raudio"
require "uing"
require "../service_workflow"

module VOVX
  private def self.build_app_controls(state : AppState) : AppControls
    # VOICEVOX をパイプで呼ぶ用途なので、入力欄は持たず、再生操作だけに絞る。
    window = UIng::Window.new("VOICEVOX 再生", WINDOW_WIDTH, WINDOW_HEIGHT, menubar: true, margined: true)
    window.resizeable = false

    root = UIng::Box.new(:vertical, padded: true)
    form = UIng::Form.new(padded: true)

    voice_combobox = UIng::Combobox.new
    populate_voice_combobox(voice_combobox, state)
    voice_combobox.on_selected do |idx|
      next if idx < 0
      state.selected_speaker = state.styles[idx].speaker_id
    end
    form.append("声", voice_combobox)
    voice_combobox.disable

    speed_box = UIng::Box.new(:horizontal, padded: true)
    speed_slider = UIng::Slider.new(50, 200)
    speed_slider.value = state.slider_percent
    speed_label = UIng::Label.new("#{state.slider_percent}%")
    speed_slider.on_changed do |value|
      state.slider_percent = value
      speed_label.text = "#{value}%"
    end
    speed_box.append(speed_slider, true)
    speed_box.append(speed_label)
    form.append("速度", speed_box)
    root.append(form, true)

    status_label = UIng::Label.new(state.sentences.empty? ? "入力テキストなし" : "待機中")
    root.append(status_label)

    buttons = UIng::Box.new(:horizontal, padded: true)
    play_button = UIng::Button.new("再生")
    stop_button = UIng::Button.new("停止")
    play_button.disable
    stop_button.disable
    buttons.append(play_button, true)
    buttons.append(stop_button, true)
    root.append(buttons)

    window.child = root
    AppControls.new(window, voice_combobox, speed_slider, speed_label, status_label, play_button, stop_button)
  end

  private def self.build_app_menu(state : AppState) : Nil
    tools_menu = UIng::Menu.new("Tools")
    settings_item = tools_menu.append_preferences_item
    settings_item.on_clicked do
      show_settings_window(state)
    end

    {% if flag?(:darwin) %}
      tools_menu.append_separator
      tools_menu.append_item("サービスメニューに追加/更新").on_clicked do |window|
        success, message = install_service_workflow
        if success
          window.msg_box("VOVX", message)
        else
          window.msg_box_error("VOVX", message)
        end
      end
      tools_menu.append_item("サービスメニューから削除").on_clicked do |window|
        success, message = uninstall_service_workflow
        if success
          window.msg_box("VOVX", message)
        else
          window.msg_box_error("VOVX", message)
        end
      end
      tools_menu.append_item("サービスメニューのフォルダを開く").on_clicked do |window|
        success, message = open_service_workflow_directory
        unless success
          window.msg_box_error("VOVX", message)
        end
      end
    {% end %}

    help_menu = UIng::Menu.new("Help")
    about_item = help_menu.append_about_item
    about_item.on_clicked do |window|
      window.msg_box("About VOVX", "#{REPOSITORY_URL}\n#{VERSION}")
    end
  end

  private def self.wire_playback_controls(controls : AppControls, state : AppState, controller : PlaybackController, startup_context : Fiber::ExecutionContext::Parallel) : Nil
    controls.play_button.on_clicked do
      unless state.voicevox_ready?
        start_voicevox_from_ui(controls, state, controller, startup_context)
        next
      end

      next if controller.running?

      start_playback(controls, state, controller)
    end

    controls.stop_button.on_clicked do
      next unless controller.running?

      log_event("ui.stop_clicked")
      controls.status_label.text = "停止中..."
      controller.request_stop
    end
  end

  private def self.start_voicevox_from_ui(controls : AppControls, state : AppState, controller : PlaybackController, startup_context : Fiber::ExecutionContext::Parallel) : Nil
    controls.play_button.disable
    controls.status_label.text = "VOICEVOX 起動中..."
    prepare_voicevox_engine(controls, state, controller, startup_context, start_if_needed: true)
  end

  private def self.start_playback(controls : AppControls, state : AppState, controller : PlaybackController) : Nil
    if state.sentences.empty?
      controls.status_label.text = "入力テキストなし"
      return
    end

    log_event("ui.play_clicked")
    controls.play_button.disable
    controls.stop_button.enable
    controls.voice_combobox.disable
    controls.speed_slider.disable
    controls.status_label.text = "開始中..."

    ensure_audio_device_ready(state)

    on_status = ->(message : String) { controls.status_label.text = message }
    on_finish = ->(interrupted : Bool) {
      controls.play_button.enable
      controls.stop_button.disable
      controls.voice_combobox.enable
      controls.speed_slider.enable
      controls.status_label.text = interrupted ? "停止しました" : "再生完了"

      if !interrupted && state.quit_after_playback?
        log_event("ui.quit_after_playback")
        save_user_settings(state.to_user_settings)
        close_settings_window(state)
        controls.window.destroy
        UIng.quit
      end
    }
    controller.start(state.sentences, state.selected_speaker, state.rate, on_status, on_finish)
  end

  private def self.ensure_audio_device_ready(state : AppState) : Nil
    return if state.audio_ready?

    Raudio::AudioDevice.init
    state.audio_ready = Raudio::AudioDevice.ready?
    log_event("audio_device.ready=#{state.audio_ready?}")
  rescue ex
    log_event("audio_device.init_failed message=#{ex.message}")
  end

  private def self.populate_voice_combobox(voice_combobox : UIng::Combobox, state : AppState) : Nil
    voice_combobox.clear

    selected_index = -1
    target_speaker = state.preferred_speaker || state.selected_speaker
    selected_speaker = state.selected_speaker

    state.styles.each_with_index do |style, i|
      voice_combobox.append(style.label)
      if style.speaker_id == target_speaker
        selected_index = i
        selected_speaker = style.speaker_id
      end
    end

    if selected_index < 0
      state.styles.each_with_index do |style, i|
        if style.speaker_id == DEFAULT_SPEAKER
          selected_index = i
          selected_speaker = style.speaker_id
          break
        end
      end
    end

    if selected_index < 0
      selected_index = 0
      selected_speaker = state.styles.first.speaker_id
    end

    state.selected_speaker = selected_speaker
    state.preferred_speaker = nil if selected_speaker == target_speaker
    voice_combobox.selected = selected_index.to_i32
  end
end

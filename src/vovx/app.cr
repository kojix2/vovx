require "raudio"
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
    property settings_window : UIng::Window?

    def initialize(@sentences : Array(String), @styles : Array(VoiceStyleOption), default_rate : Float64, settings : UserSettings)
      @preferred_speaker = settings.speaker_id
      @selected_speaker = settings.speaker_id || styles.first.speaker_id
      @slider_percent = ((settings.rate || default_rate) * 100).round.to_i.clamp(50, 200)
      @auto_play = settings.auto_play?
      @quit_after_playback = settings.quit_after_playback?
      @settings_window = nil
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

  # 小さな操作ウィンドウを作り、声・速度・再生/停止を扱う。
  # 実際の合成と再生は PlaybackController に委譲する。
  def self.run_app(sentences : Array(String), initial_styles : Array(VoiceStyleOption), default_rate : Float64 = DEFAULT_RATE) : Nil
    log_event("app.run sentences=#{sentences.size} styles=#{initial_styles.size}")

    state = AppState.new(sentences, initial_styles, default_rate, load_user_settings)

    # macOS の AppKit 初期化と main loop は OS main thread で実行する必要がある。
    # Engine 起動確認や HTTP 取得は、この後で background context 側へ逃がす。
    log_event("ui.init.start")
    UIng.init
    log_event("ui.init.done")

    begin
      controller = PlaybackController.new
      startup_context = Fiber::ExecutionContext::Parallel.new("vovx-startup", 1)
      build_app_menu(state)
      controls = build_app_controls(state)
      window = controls.window

      wire_playback_controls(controls, state, controller, startup_context)

      window.on_closing do
        log_event("ui.window_closing")
        save_user_settings(state.to_user_settings)
        close_settings_window(state)
        controller.request_stop
        UIng.quit
        true
      end

      center_window_on_main_screen(window, WINDOW_WIDTH, WINDOW_HEIGHT)
      window.show

      prepare_voicevox_engine(controls, state, controller, startup_context, start_if_needed: state.auto_play?)

      UIng.timer(100) do
        focus_current_process
        0
      end
      UIng.main
    ensure
      close_settings_window(state)
      UIng.uninit
      begin
        if state.audio_ready?
          Raudio::AudioDevice.close
          log_event("audio_device.closed")
        end
      rescue
      end
    end
  end

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

  private def self.apply_voicevox_status(controls : AppControls, state : AppState, controller : PlaybackController, styles : Array(VoiceStyleOption), message : String, ready : Bool) : Nil
    controls.status_label.text = ready && state.sentences.empty? ? "入力テキストなし" : message
    state.voicevox_ready = ready

    if ready
      state.styles = styles
      populate_voice_combobox(controls.voice_combobox, state)
      controls.voice_combobox.enable
      controls.play_button.text = "再生"
    else
      controls.play_button.text = "起動"
    end

    if ready && state.sentences.empty?
      controls.play_button.disable
    else
      controls.play_button.enable
    end
  end

  private def self.prepare_voicevox_engine(controls : AppControls, state : AppState, controller : PlaybackController, startup_context : Fiber::ExecutionContext::Parallel, start_if_needed : Bool) : Nil
    startup_context.spawn(name: "vovx-startup") do
      styles = [] of VoiceStyleOption
      message = "待機中"
      ready = false
      can_fetch_styles = true

      begin
        unless voicevox_engine_running?
          log_event("voicevox_engine.not_running")
          if start_if_needed
            log_event("voicevox_start.requested")
            unless start_voicevox_application
              message = "#{VOICEVOX_APP} を起動できませんでした"
              can_fetch_styles = false
              log_event("voicevox_start.failed")
            end

            if can_fetch_styles
              if wait_for_voicevox_engine(on_attempt: ->(attempt : Int32, max_attempts : Int32) {
                   UIng.queue_main do
                     controls.status_label.text = "VOICEVOX 起動中... #{attempt}/#{max_attempts}"
                   end
                 })
                log_event("voicevox_start.ready")
              else
                message = "VOICEVOX Engine の起動待ちに失敗しました"
                can_fetch_styles = false
                log_event("voicevox_start.timeout")
              end
            end
          else
            message = "VOICEVOX Engine が起動していません"
            can_fetch_styles = false
          end
        end

        if can_fetch_styles
          styles = fetch_voice_styles
          ready = true
          message = "待機中"
        end
      rescue ex
        message = "VOICEVOX 準備失敗: #{ex.message}"
        log_event("voicevox_start.prepare_failed message=#{ex.message}")
      end

      UIng.queue_main do
        if styles.empty? && start_if_needed
          controls.window.msg_box_error("VOVX", message)
        end
        apply_voicevox_status(controls, state, controller, styles, message, ready)
        start_auto_playback_if_ready(controls, state, controller, ready)
      end
    end
  end

  private def self.start_auto_playback_if_ready(controls : AppControls, state : AppState, controller : PlaybackController, ready : Bool) : Nil
    return unless auto_playback_ready?(state, ready)

    state.auto_play_started = true
    start_playback(controls, state, controller)
  end

  private def self.auto_playback_ready?(state : AppState, ready : Bool) : Bool
    ready && state.auto_play? && !state.auto_play_started? && !state.sentences.empty?
  end
end

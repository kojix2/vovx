require "raudio"
require "uing"

module VOVX
  private class AppState
    property styles : Array(VoiceStyleOption)
    property selected_speaker : Int32
    property slider_percent : Int32
    property? audio_ready = false
    property? voicevox_ready = false

    def initialize(@styles : Array(VoiceStyleOption), default_rate : Float64)
      @selected_speaker = styles.first.speaker_id
      @slider_percent = (default_rate * 100).round.to_i.clamp(50, 200)
    end

    def rate : Float64
      slider_percent / 100.0
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

    state = AppState.new(initial_styles, default_rate)

    # macOS の AppKit 初期化と main loop は OS main thread で実行する必要がある。
    # Engine 起動確認や HTTP 取得は、この後で background context 側へ逃がす。
    log_event("ui.init.start")
    UIng.init
    log_event("ui.init.done")

    begin
      controller = PlaybackController.new(sentences)
      startup_context = Fiber::ExecutionContext::Parallel.new("vovx-startup", 1)
      controls = build_app_controls(state)
      window = controls.window

      wire_playback_controls(controls, state, controller, startup_context)

      window.on_closing do
        log_event("ui.window_closing")
        controller.request_stop
        UIng.quit
        true
      end

      center_window_on_main_screen(window, WINDOW_WIDTH, WINDOW_HEIGHT)
      window.show
      focus_current_process

      prepare_voicevox_engine(controls, state, startup_context, start_if_needed: false)

      UIng.timer(100) do
        focus_current_process
        0
      end
      UIng.main
    ensure
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
    window = UIng::Window.new("VOICEVOX 再生", WINDOW_WIDTH, WINDOW_HEIGHT, margined: true)
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

    status_label = UIng::Label.new("待機中")
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

  private def self.wire_playback_controls(controls : AppControls, state : AppState, controller : PlaybackController, startup_context : Fiber::ExecutionContext::Parallel) : Nil
    controls.play_button.on_clicked do
      unless state.voicevox_ready?
        start_voicevox_from_ui(controls, state, startup_context)
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

  private def self.start_voicevox_from_ui(controls : AppControls, state : AppState, startup_context : Fiber::ExecutionContext::Parallel) : Nil
    controls.play_button.disable
    controls.status_label.text = "VOICEVOX 起動中..."
    prepare_voicevox_engine(controls, state, startup_context, start_if_needed: true)
  end

  private def self.start_playback(controls : AppControls, state : AppState, controller : PlaybackController) : Nil
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
    }
    controller.start(state.selected_speaker, state.rate, on_status, on_finish)
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
    selected_speaker = state.selected_speaker

    state.styles.each_with_index do |style, i|
      voice_combobox.append(style.label)
      if style.speaker_id == state.selected_speaker
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
    voice_combobox.selected = selected_index.to_i32
  end

  private def self.apply_voicevox_status(controls : AppControls, state : AppState, styles : Array(VoiceStyleOption), message : String, ready : Bool) : Nil
    controls.status_label.text = message
    state.voicevox_ready = ready

    if ready
      state.styles = styles
      populate_voice_combobox(controls.voice_combobox, state)
      controls.voice_combobox.enable
      controls.play_button.text = "再生"
    else
      controls.play_button.text = "起動"
    end

    controls.play_button.enable
  end

  private def self.prepare_voicevox_engine(controls : AppControls, state : AppState, startup_context : Fiber::ExecutionContext::Parallel, start_if_needed : Bool) : Nil
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
        apply_voicevox_status(controls, state, styles, message, ready)
      end
    end
  end
end

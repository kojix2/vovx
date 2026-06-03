require "raudio"
require "uing"

module VOVX
  # 小さな操作ウィンドウを作り、声・速度・再生/停止を扱う。
  # 実際の合成と再生は PlaybackController に委譲する。
  def self.run_app(sentences : Array(String), initial_styles : Array(VoiceStyleOption), default_rate : Float64 = DEFAULT_RATE) : Nil
    log_event("app.run sentences=#{sentences.size} styles=#{initial_styles.size}")

    styles = initial_styles
    selected_speaker = styles.first.speaker_id
    slider_percent = (default_rate * 100).round.to_i.clamp(50, 200)

    # macOS の AppKit 初期化と main loop は OS main thread で実行する必要がある。
    # Engine 起動確認や HTTP 取得は、この後で background context 側へ逃がす。
    log_event("ui.init.start")
    UIng.init
    log_event("ui.init.done")

    begin
      controller = PlaybackController.new(sentences)
      startup_context = Fiber::ExecutionContext::Parallel.new("vovx-startup", 1)
      audio_ready = false
      voicevox_ready = false

      # VOICEVOX をパイプで呼ぶ用途なので、入力欄は持たず、再生操作だけに絞る。
      window = UIng::Window.new("VOICEVOX 再生", WINDOW_WIDTH, WINDOW_HEIGHT, margined: true)
      window.resizeable = false

      root = UIng::Box.new(:vertical, padded: true)
      form = UIng::Form.new(padded: true)

      # DEFAULT_SPEAKER が一覧にある場合は初期選択にする。なければ先頭を使う。
      voice_combobox = UIng::Combobox.new
      populate_voice_combobox(voice_combobox, styles, selected_speaker)
      voice_combobox.on_selected do |idx|
        next if idx < 0
        selected_speaker = styles[idx].speaker_id
      end
      form.append("声", voice_combobox)
      voice_combobox.disable

      # VOICEVOX の speedScale は小数だが、UI では 50% から 200% の整数で扱う。
      speed_box = UIng::Box.new(:horizontal, padded: true)
      speed_slider = UIng::Slider.new(50, 200)
      speed_slider.value = slider_percent
      speed_label = UIng::Label.new("#{slider_percent}%")
      speed_slider.on_changed do |value|
        slider_percent = value
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

      # 再生中は話者と速度を固定し、停止だけ受け付ける。
      play_button.on_clicked do
        unless voicevox_ready
          play_button.disable
          status_label.text = "VOICEVOX 起動中..."
          prepare_voicevox_engine(startup_context, window, start_if_needed: true) do |loaded_styles, message, ready|
            status_label.text = message
            voicevox_ready = ready
            if ready
              styles = loaded_styles
              selected_speaker = populate_voice_combobox(voice_combobox, styles, selected_speaker)
              voice_combobox.enable
              play_button.text = "再生"
            end
            play_button.enable
          end
          next
        end

        next if controller.running?

        log_event("ui.play_clicked")
        play_button.disable
        stop_button.enable
        voice_combobox.disable
        speed_slider.disable
        status_label.text = "開始中..."

        unless audio_ready
          begin
            Raudio::AudioDevice.init
            audio_ready = Raudio::AudioDevice.ready?
            log_event("audio_device.ready=#{audio_ready}")
          rescue ex
            log_event("audio_device.init_failed message=#{ex.message}")
          end
        end

        on_status = ->(message : String) { status_label.text = message }
        on_finish = ->(interrupted : Bool) {
          play_button.enable
          stop_button.disable
          voice_combobox.enable
          speed_slider.enable
          status_label.text = interrupted ? "停止しました" : "再生完了"
        }
        controller.start(selected_speaker, slider_percent / 100.0, on_status, on_finish)
      end

      stop_button.on_clicked do
        next unless controller.running?

        log_event("ui.stop_clicked")
        status_label.text = "停止中..."
        controller.request_stop
      end

      # ウィンドウを閉じる操作は停止要求として扱い、ワーカー側の後始末を走らせる。
      window.on_closing do
        log_event("ui.window_closing")
        controller.request_stop
        UIng.quit
        true
      end

      window.child = root
      center_window_on_main_screen(window, WINDOW_WIDTH, WINDOW_HEIGHT)
      window.show
      focus_current_process

      prepare_voicevox_engine(startup_context, window, start_if_needed: false) do |loaded_styles, message, ready|
        status_label.text = message
        voicevox_ready = ready
        if ready
          styles = loaded_styles
          selected_speaker = populate_voice_combobox(voice_combobox, styles, selected_speaker)
          voice_combobox.enable
          play_button.text = "再生"
          play_button.enable
        else
          play_button.text = "起動"
          play_button.enable
        end
      end

      UIng.timer(100) do
        focus_current_process
        0
      end
      UIng.main
    ensure
      UIng.uninit
      begin
        if audio_ready
          Raudio::AudioDevice.close
          log_event("audio_device.closed")
        end
      rescue
      end
    end
  end

  private def self.populate_voice_combobox(voice_combobox : UIng::Combobox, styles : Array(VoiceStyleOption), current_speaker : Int32) : Int32
    selected_speaker = current_speaker
    voice_combobox.clear

    selected_index = -1
    styles.each_with_index do |style, i|
      voice_combobox.append(style.label)
      if style.speaker_id == current_speaker
        selected_index = i
        selected_speaker = style.speaker_id
      end
    end

    if selected_index < 0
      styles.each_with_index do |style, i|
        if style.speaker_id == DEFAULT_SPEAKER
          selected_index = i
          selected_speaker = style.speaker_id
          break
        end
      end
    end

    if selected_index < 0
      selected_index = 0
      selected_speaker = styles.first.speaker_id
    end

    voice_combobox.selected = selected_index.to_i32
    selected_speaker
  end

  private def self.prepare_voicevox_engine(startup_context : Fiber::ExecutionContext::Parallel, window : UIng::Window, start_if_needed : Bool, &on_ready : Array(VoiceStyleOption), String, Bool -> Nil) : Nil
    startup_context.spawn(name: "vovx-startup") do
      styles = [] of VoiceStyleOption
      message = "待機中"
      ready = false

      begin
        unless voicevox_engine_running?
          log_event("voicevox_engine.not_running")
          if start_if_needed
            log_event("voicevox_start.requested")
            unless start_voicevox_application
              message = "#{VOICEVOX_APP} を起動できませんでした"
              log_event("voicevox_start.failed")
            end

            if message == "待機中"
              if wait_for_voicevox_engine
                log_event("voicevox_start.ready")
              else
                message = "VOICEVOX Engine の起動待ちに失敗しました"
                log_event("voicevox_start.timeout")
              end
            end
          else
            message = "VOICEVOX Engine が起動していません"
          end
        end

        if message == "待機中"
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
          window.msg_box_error("VOVX", message)
        end
        on_ready.call(styles, message, ready)
      end
    end
  end
end

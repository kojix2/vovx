require "raudio"
require "uing"

module VOVX
  # 小さな操作ウィンドウを作り、声・速度・再生/停止を扱う。
  # 実際の合成と再生は PlaybackController に委譲する。
  def self.run_app(sentences : Array(String), styles : Array(VoiceStyleOption), default_rate : Float64 = DEFAULT_RATE) : Nil
    log_event("app.run sentences=#{sentences.size} styles=#{styles.size}")

    selected_speaker = styles.first.speaker_id
    slider_percent = (default_rate * 100).round.to_i.clamp(50, 200)

    # macOS の AppKit 初期化は、音声デバイスや別 execution context を作る前に済ませる。
    # VOICEVOX を起動した直後の経路で、順序が逆だと uiInit 付近で落ちることがある。
    log_event("ui.init.start")
    UIng.init
    log_event("ui.init.done")

    # 音声デバイス初期化に失敗しても、後続のログで原因を追えるようにして UI は起動する。
    begin
      controller = PlaybackController.new(sentences)

      begin
        Raudio::AudioDevice.init
        log_event("audio_device.ready=#{Raudio::AudioDevice.ready?}")
      rescue ex
        log_event("audio_device.init_failed message=#{ex.message}")
      end

      # VOICEVOX をパイプで呼ぶ用途なので、入力欄は持たず、再生操作だけに絞る。
      window = UIng::Window.new("VOICEVOX 再生", WINDOW_WIDTH, WINDOW_HEIGHT, margined: true)
      window.resizeable = false

      root = UIng::Box.new(:vertical, padded: true)
      form = UIng::Form.new(padded: true)

      # DEFAULT_SPEAKER が一覧にある場合は初期選択にする。なければ先頭を使う。
      voice_combobox = UIng::Combobox.new
      selected_index = -1
      styles.each_with_index do |style, i|
        voice_combobox.append(style.label)
        if style.speaker_id == DEFAULT_SPEAKER
          voice_combobox.selected = i.to_i32
          selected_index = i
          selected_speaker = style.speaker_id
        end
      end
      if selected_index < 0
        voice_combobox.selected = 0
        selected_speaker = styles.first.speaker_id
      end
      voice_combobox.on_selected do |idx|
        next if idx < 0
        selected_speaker = styles[idx].speaker_id
      end
      form.append("声", voice_combobox)

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
      stop_button.disable
      buttons.append(play_button, true)
      buttons.append(stop_button, true)
      root.append(buttons)

      # 再生中は話者と速度を固定し、停止だけ受け付ける。
      play_button.on_clicked do
        next if controller.running?

        log_event("ui.play_clicked")
        play_button.disable
        stop_button.enable
        voice_combobox.disable
        speed_slider.disable
        status_label.text = "開始中..."

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
      UIng.timer(100) do
        focus_current_process
        0
      end
      UIng.main
    ensure
      UIng.uninit
      begin
        Raudio::AudioDevice.close
        log_event("audio_device.closed")
      rescue
      end
    end
  end
end

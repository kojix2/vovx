require "raudio"
require "uing"
require "./platform/screen"
require "./ui/app_state"
require "./ui/settings_window"
require "./ui/voicevox_startup"
require "./ui/main_window"

module VOVX
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
      exporter = AudioExporter.new
      startup_context = Fiber::ExecutionContext::Parallel.new("vovx-startup", 1)
      controls_ref = nil.as(AppControls?)
      controls = -> {
        if current_controls = controls_ref
          current_controls
        else
          raise "app controls are not ready"
        end
      }
      build_app_menu(state, controller, exporter, controls)
      controls = build_app_controls(state)
      controls_ref = controls
      window = controls.window

      wire_playback_controls(controls, state, controller, startup_context)

      window.on_closing do
        log_event("ui.window_closing")
        request_app_close(controls, state, controller, exporter)
        false
      end
      UIng.on_should_quit do
        request_app_close(controls, state, controller, exporter)
        false
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
      state.closing = true
      state.startup_cancellation.cancel
      if current_controller = controller
        current_controller.request_stop
        current_controller.wait
      end
      if current_exporter = exporter
        current_exporter.request_stop
        current_exporter.wait
      end
      while state.startup_running?
        sleep 10.milliseconds
      end
      close_settings_window(state)
      # uiUninit traps if a root uiWindow is still allocated.
      if main_window = window
        main_window.destroy unless main_window.released?
      end
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

  private def self.request_app_close(controls : AppControls, state : AppState, controller : PlaybackController, exporter : AudioExporter) : Nil
    return if state.closing?

    state.closing = true
    state.startup_cancellation.cancel
    controller.request_stop
    exporter.request_stop
    controls.play_button.disable
    controls.stop_button.disable
    controls.status_label.text = "終了中..."

    # OS main loop を動かしたまま全ワーカーの後始末を待つ。
    UIng.timer(20) do
      if controller.running? || exporter.running? || state.startup_running?
        1
      else
        save_user_settings(state.to_user_settings)
        close_settings_window(state)
        controls.window.destroy
        UIng.quit
        0
      end
    end
  end
end

require "uing"

module VOVX
  private def self.apply_voicevox_status(controls : AppControls, state : AppState, styles : Array(VoiceStyleOption), message : String, ready : Bool) : Nil
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
    return if state.closing?
    cancellation = state.startup_cancellation
    state.startup_running = true
    startup_context.spawn(name: "vovx-startup") do
      begin
        on_attempt = ->(attempt : Int32, max_attempts : Int32) {
          UIng.queue_main do
            next if state.closing?
            controls.status_label.text = "VOICEVOX 起動中... #{attempt}/#{max_attempts}"
          end
        }
        styles, message, ready = load_voicevox_status(start_if_needed, cancellation, on_attempt)
        unless cancellation.cancelled?
          UIng.queue_main do
            next if state.closing?
            if styles.empty? && start_if_needed
              controls.window.msg_box_error("VOVX", message)
            end
            apply_voicevox_status(controls, state, styles, message, ready)
            start_auto_playback_if_ready(controls, state, controller, ready)
          end
        end
      rescue CancelledError
        # 終了要求は準備失敗のダイアログにしない。
      end
    ensure
      state.startup_running = false
    end
  rescue ex
    state.startup_running = false
    raise ex
  end

  private def self.load_voicevox_status(start_if_needed : Bool, cancellation : CancellationToken, on_attempt : Proc(Int32, Int32, Nil)) : Tuple(Array(VoiceStyleOption), String, Bool)
    unless voicevox_engine_running?(cancellation)
      log_event("voicevox_engine.not_running")
      return {[] of VoiceStyleOption, "VOICEVOX Engine が起動していません", false} unless start_if_needed

      cancellation.check!
      log_event("voicevox_start.requested")
      unless start_voicevox_application
        log_event("voicevox_start.failed")
        return {[] of VoiceStyleOption, "#{VOICEVOX_APP} を起動できませんでした", false}
      end
      unless wait_for_voicevox_engine(cancellation: cancellation, on_attempt: on_attempt)
        log_event("voicevox_start.timeout")
        return {[] of VoiceStyleOption, "VOICEVOX Engine の起動待ちに失敗しました", false}
      end
      log_event("voicevox_start.ready")
    end
    {fetch_voice_styles(cancellation), "待機中", true}
  rescue ex : CancelledError
    raise ex
  rescue ex
    log_event("voicevox_start.prepare_failed message=#{ex.message}")
    {[] of VoiceStyleOption, "VOICEVOX 準備失敗: #{ex.message}", false}
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

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

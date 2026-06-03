require "raudio"
require "uing"

module VOVX
  # 合成と再生を非同期に進めるコントローラ。
  # GUI スレッドを塞がないよう、合成用と再生用に別々の execution context を使う。
  class PlaybackController
    @mutex = Mutex.new
    @running = false
    @stop_requested = false
    @current_sound : Raudio::Sound? = nil
    @work_queue : Channel(File)? = nil

    # ワーカー Fiber を明示的に分離し、HTTP 合成と音声再生が UI を止めないようにする。
    @synthesis_context : Fiber::ExecutionContext::Parallel = Fiber::ExecutionContext::Parallel.new("vovx-synth", 1)
    @playback_context : Fiber::ExecutionContext::Parallel = Fiber::ExecutionContext::Parallel.new("vovx-playback", 1)

    def initialize(@sentences : Array(String))
    end

    def replace_sentences(sentences : Array(String)) : Nil
      @mutex.synchronize do
        @sentences = sentences
      end
      VOVX.log_event("playback.sentences_replaced sentences=#{sentences.size}")
    end

    def running? : Bool
      @mutex.synchronize { @running }
    end

    # 現在の合成・再生を止める。
    # Channel を閉じ、再生中の Sound があれば stop して、各ワーカーの ensure に後始末を任せる。
    def request_stop : Nil
      VOVX.log_event("stop.requested")
      sound, queue = @mutex.synchronize do
        @stop_requested = true
        {@current_sound, @work_queue}
      end

      begin
        queue.try &.close
      rescue Channel::ClosedError
      end

      begin
        sound.try &.stop
      rescue
      end
    end

    # 再生処理を開始する。すでに実行中の場合は false を返す。
    # on_status/on_finish は必ず UIng.queue_main 経由で呼び、UI 更新をメインスレッドに戻す。
    def start(speaker_id : Int32, rate : Float64, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Bool
      sentences = @mutex.synchronize do
        return false if @running
        @running = true
        @stop_requested = false
        @sentences.dup
      end
      sentence_count = sentences.size
      VOVX.log_event("playback.start speaker=#{speaker_id} rate=#{rate} sentences=#{sentence_count}")

      work_queue = Channel(File).new(2)
      @mutex.synchronize { @work_queue = work_queue }

      begin
        spawn_producer(work_queue, sentences, speaker_id, rate, on_status)
      rescue ex
        fail_start("producer.spawn_failed message=#{ex.message}", on_status, on_finish)
        return true
      end

      begin
        spawn_consumer(work_queue, sentence_count, on_status, on_finish)
      rescue ex
        fail_start("consumer.spawn_failed message=#{ex.message}", on_status, on_finish)
        return true
      end

      true
    end

    # producer: 文ごとに WAV を合成し、再生側へ渡す。
    # バッファを小さくして、停止要求後に作り過ぎた一時ファイルが残りにくいようにする。
    private def spawn_producer(work_queue : Channel(File), sentences : Array(String), speaker_id : Int32, rate : Float64, on_status : Proc(String, Nil)) : Nil
      VOVX.log_event("producer.spawn")
      @synthesis_context.spawn(name: "vovx-synth-producer") do
        begin
          sentences.each_with_index do |sentence, i|
            break if stop_requested?

            queue_status(on_status, "合成中 #{i + 1}/#{sentences.size}")
            VOVX.log_event("producer.sentence index=#{i + 1}")

            wav = begin
              VOVX.synthesize(sentence, speaker_id, rate)
            rescue ex
              VOVX.log_event("producer.error index=#{i + 1} message=#{ex.message}")
              queue_status(on_status, "合成失敗 #{i + 1}/#{sentences.size}: #{ex.message}")
              next
            end

            begin
              work_queue.send(wav)
              VOVX.log_event("producer.enqueue index=#{i + 1}")
            rescue Channel::ClosedError
              wav.close
              File.delete?(wav.path)
              break
            end
          end
        rescue ex
          VOVX.log_event("producer.fatal message=#{ex.message}")
          queue_status(on_status, "エラー: #{ex.message}")
        ensure
          work_queue.close
          VOVX.log_event("producer.done")
        end
      end
    end

    # consumer: 合成済み WAV を受け取り、1 件ずつ再生して削除する。
    private def spawn_consumer(work_queue : Channel(File), sentence_count : Int32, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Nil
      VOVX.log_event("consumer.spawn")
      @playback_context.spawn(name: "vovx-playback-consumer") do
        interrupted = false
        played = 0
        begin
          while wav = work_queue.receive?
            played += 1
            begin
              if stop_requested?
                interrupted = true
                begin
                  work_queue.close
                rescue Channel::ClosedError
                end
                VOVX.log_event("consumer.stop_detected played=#{played}")
                break
              end

              queue_status(on_status, "再生中 #{played}/#{sentence_count}")
              VOVX.log_event("consumer.play index=#{played} path=#{wav.path}")
              play_wav(wav.path)
            ensure
              wav.close
              File.delete?(wav.path)
              VOVX.log_event("consumer.cleanup index=#{played}")
            end
          end

          interrupted ||= stop_requested?
        rescue ex
          interrupted = true
          VOVX.log_event("consumer.fatal message=#{ex.message}")
          queue_status(on_status, "エラー: #{ex.message}")
        ensure
          finish_playback(interrupted, on_finish)
        end
      end
    end

    private def finish_playback(interrupted : Bool, on_finish : Proc(Bool, Nil)) : Nil
      @mutex.synchronize do
        @running = false
        @stop_requested = false
        @current_sound = nil
        @work_queue = nil
      end
      VOVX.log_event("playback.finish interrupted=#{interrupted}")
      UIng.queue_main do
        on_finish.call(interrupted)
      end
    end

    # ワーカー起動自体に失敗した場合の共通復旧処理。
    private def fail_start(message : String, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Nil
      VOVX.log_event(message)
      @mutex.synchronize do
        @running = false
        @stop_requested = false
        @current_sound = nil
        @work_queue = nil
      end
      queue_status(on_status, "ワーカー起動失敗")
      UIng.queue_main do
        on_finish.call(true)
      end
    end

    private def stop_requested? : Bool
      @mutex.synchronize { @stop_requested }
    end

    # libui の部品更新はメインループ上で実行する。
    private def queue_status(on_status : Proc(String, Nil), message : String) : Nil
      UIng.queue_main do
        on_status.call(message)
      end
    end

    # WAV ファイルを同期的に再生する。
    # 停止要求を短い間隔で確認し、要求があれば Sound.stop を試みる。
    private def play_wav(path : String) : Nil
      VOVX.log_event("player.start path=#{path}")
      sound = Raudio::Sound.load(path)
      begin
        @mutex.synchronize do
          @current_sound = sound
        end

        sound.play
        while sound.playing?
          break if stop_requested?
          sleep 10.milliseconds
        end

        if stop_requested?
          begin
            sound.stop
          rescue
          end
        end
      ensure
        sound.release
      end

      VOVX.log_event("player.done path=#{path}")
    ensure
      @mutex.synchronize do
        @current_sound = nil
      end
    end
  end
end

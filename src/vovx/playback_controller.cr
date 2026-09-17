require "raudio"
require "uing"
require "./voicevox_client"

module VOVX
  # 合成と再生は別々の context、Sound の操作は再生 context だけで行う。
  class PlaybackController
    @mutex = Mutex.new
    @running = false
    @cancellation : CancellationToken? = nil
    @work_queue : Channel(File)? = nil
    @workers_remaining = 0
    @error_message : String? = nil
    @synthesis_context = Fiber::ExecutionContext::Parallel.new("vovx-synth", 1)
    @playback_context = Fiber::ExecutionContext::Parallel.new("vovx-playback", 1)

    def running? : Bool
      @mutex.synchronize { @running }
    end

    def error_message : String?
      @mutex.synchronize { @error_message }
    end

    def request_stop : Nil
      VOVX.log_event("stop.requested")
      @mutex.synchronize do
        @cancellation.try &.cancel
        @work_queue.try &.close
      end
    end

    # UI の main loop を抜けた後、資源を破棄する前に呼ぶ。
    def wait : Nil
      while running?
        sleep 10.milliseconds
      end
    end

    # Bool の完了引数は従来どおり、停止または失敗なら true。
    def start(sentences : Array(String), speaker_id : Int32, rate : Float64, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Bool
      work_queue = Channel(File).new(2)
      cancellation = CancellationToken.new
      playback_sentences = @mutex.synchronize do
        return false if @running
        @running = true
        @error_message = nil
        @cancellation = cancellation
        @work_queue = work_queue
        @workers_remaining = 2
        sentences.dup
      end
      VOVX.log_event("playback.start speaker=#{speaker_id} rate=#{rate} sentences=#{playback_sentences.size}")

      consumer_started = false
      producer_started = false
      begin
        spawn_consumer(work_queue, cancellation, playback_sentences.size, on_status, on_finish)
        consumer_started = true
        spawn_producer(work_queue, cancellation, playback_sentences, speaker_id, rate, on_status, on_finish)
        producer_started = true
      rescue ex
        record_error("ワーカー起動失敗: #{ex.message}")
        request_stop
        worker_finished(cancellation, on_finish) unless consumer_started
        worker_finished(cancellation, on_finish) unless producer_started
      end
      true
    end

    private def spawn_producer(work_queue : Channel(File), cancellation : CancellationToken, sentences : Array(String), speaker_id : Int32, rate : Float64, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Nil
      @synthesis_context.spawn(name: "vovx-synth-producer") do
        sentences.each_with_index do |sentence, i|
          cancellation.check!
          queue_status(on_status, "合成中 #{i + 1}/#{sentences.size}")
          wav = synthesize(sentence, speaker_id, rate, cancellation)
          begin
            cancellation.check!
            work_queue.send(wav)
          rescue ex
            VOVX.cleanup_wav(wav)
            raise ex
          end
        end
      rescue CancelledError | Channel::ClosedError
        # 停止時の残りファイルは consumer が回収する。
      rescue ex
        record_error("合成失敗: #{ex.message}")
        queue_status(on_status, "合成失敗: #{ex.message}")
        request_stop
      ensure
        work_queue.close
        worker_finished(cancellation, on_finish)
      end
    end

    private def spawn_consumer(work_queue : Channel(File), cancellation : CancellationToken, sentence_count : Int32, on_status : Proc(String, Nil), on_finish : Proc(Bool, Nil)) : Nil
      @playback_context.spawn(name: "vovx-playback-consumer") do
        played = 0
        begin
          while wav = work_queue.receive?
            begin
              next if cancellation.cancelled?
              played += 1
              queue_status(on_status, "再生中 #{played}/#{sentence_count}")
              play_wav(wav.path, cancellation)
            ensure
              VOVX.cleanup_wav(wav)
            end
          end
        rescue CancelledError
        rescue ex
          record_error("再生失敗: #{ex.message}")
          queue_status(on_status, "再生失敗: #{ex.message}")
          request_stop
        ensure
          # 再生エラーでも sender を解放し、buffer の全件を削除する。
          work_queue.close
          while wav = work_queue.receive?
            VOVX.cleanup_wav(wav)
          end
          worker_finished(cancellation, on_finish)
        end
      end
    end

    private def record_error(message : String) : Nil
      @mutex.synchronize { @error_message ||= message }
      VOVX.log_event("playback.error message=#{message}")
    end

    private def worker_finished(cancellation : CancellationToken, on_finish : Proc(Bool, Nil)) : Nil
      finished = @mutex.synchronize do
        @workers_remaining -= 1
        @workers_remaining == 0
      end
      return unless finished

      interrupted = cancellation.cancelled? || !error_message.nil?
      VOVX.log_event("playback.finish interrupted=#{interrupted}")
      begin
        dispatch { on_finish.call(interrupted) }
      ensure
        # 全ワーカーの後始末と最後の UI callback の登録まで実行中とする。
        @mutex.synchronize do
          @work_queue = nil
          @cancellation = nil
          @running = false
        end
      end
    end

    protected def synthesize(sentence : String, speaker_id : Int32, rate : Float64, cancellation : CancellationToken) : File
      VOVX.synthesize(sentence, speaker_id, rate, cancellation)
    end

    protected def dispatch(&callback : -> Nil) : Nil
      UIng.queue_main(&callback)
    end

    private def queue_status(on_status : Proc(String, Nil), message : String) : Nil
      dispatch { on_status.call(message) }
    end

    protected def play_wav(path : String, cancellation : CancellationToken) : Nil
      cancellation.check!
      sound = Raudio::Sound.load(path)
      begin
        cancellation.check!
        sound.play
        while sound.playing? && !cancellation.cancelled?
          sleep 10.milliseconds
        end
      ensure
        begin
          sound.stop if cancellation.cancelled?
        ensure
          sound.release
        end
      end
    end
  end
end

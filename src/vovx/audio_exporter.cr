require "uing"
require "./wav"
require "./voicevox_client"

module VOVX
  enum AudioExportResult
    Success
    Cancelled
    Failure
  end

  class AudioExporter
    @mutex = Mutex.new
    @running = false
    @cancellation : CancellationToken? = nil
    @context = Fiber::ExecutionContext::Parallel.new("vovx-export", 1)

    def running? : Bool
      @mutex.synchronize { @running }
    end

    def request_stop : Nil
      @mutex.synchronize { @cancellation.try &.cancel }
    end

    def wait : Nil
      while running?
        sleep 10.milliseconds
      end
    end

    def start(sentences : Array(String), speaker_id : Int32, rate : Float64, output_path : String, on_status : Proc(String, Nil), on_finish : Proc(AudioExportResult, String, Nil)) : Bool
      cancellation = CancellationToken.new
      export_sentences = @mutex.synchronize do
        return false if @running
        @running = true
        @cancellation = cancellation
        sentences.dup
      end

      VOVX.log_event("export.start speaker=#{speaker_id} rate=#{rate} sentences=#{export_sentences.size} path=#{output_path}")
      @context.spawn(name: "vovx-audio-export") do
        export_to_file(export_sentences, speaker_id, rate, output_path, cancellation, on_status, on_finish)
      end
      true
    rescue ex
      finish(AudioExportResult::Failure, "保存ワーカー起動失敗: #{ex.message}", on_finish)
      true
    end

    private def export_to_file(sentences : Array(String), speaker_id : Int32, rate : Float64, output_path : String, cancellation : CancellationToken, on_status : Proc(String, Nil), on_finish : Proc(AudioExportResult, String, Nil)) : Nil
      tmp_path = nil
      writer = nil
      result = AudioExportResult::Failure
      message : String

      begin
        cancellation.check!
        # 同じディレクトリの固有名を使い、他のプロセスや既存 .tmp を壊さない。
        temporary = File.tempfile("vovx_export_", ".tmp", dir: File.dirname(output_path))
        tmp_path = temporary.path
        temporary.close
        writer = WavWriter.new(tmp_path)

        sentences.each_with_index do |sentence, i|
          cancellation.check!
          status = "保存用に合成中 #{i + 1}/#{sentences.size}"
          dispatch { on_status.call(status) }
          wav = synthesize(sentence, speaker_id, rate, cancellation)
          begin
            cancellation.check!
            writer.append_file(wav.path)
          ensure
            VOVX.cleanup_wav(wav)
          end
        end

        writer.close
        writer = nil
        @mutex.synchronize do
          cancellation.check!
          File.rename(tmp_path, output_path)
        end
        result = AudioExportResult::Success
        message = output_path
        VOVX.log_event("export.done path=#{output_path}")
      rescue CancelledError
        result = AudioExportResult::Cancelled
        message = "保存を中断しました"
      rescue ex
        VOVX.log_event("export.error message=#{ex.message}")
        message = "保存に失敗しました: #{ex.message}"
      ensure
        begin
          writer.try &.close
        rescue
        end
        begin
          File.delete?(tmp_path) if tmp_path
        ensure
          finish(result, message, on_finish)
        end
      end
    end

    private def finish(result : AudioExportResult, message : String, on_finish : Proc(AudioExportResult, String, Nil)) : Nil
      dispatch { on_finish.call(result, message) }
    ensure
      @mutex.synchronize do
        @cancellation = nil
        @running = false
      end
    end

    protected def synthesize(sentence : String, speaker_id : Int32, rate : Float64, cancellation : CancellationToken) : File
      VOVX.synthesize(sentence, speaker_id, rate, cancellation)
    end

    protected def dispatch(&callback : -> Nil) : Nil
      UIng.queue_main(&callback)
    end
  end
end

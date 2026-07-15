require "uing"
require "./wav"

module VOVX
  enum AudioExportResult
    Success
    Cancelled
    Failure
  end

  class AudioExporter
    @mutex = Mutex.new
    @running = false
    @stop_requested = false
    @context = Fiber::ExecutionContext::Parallel.new("vovx-export", 1)

    def running? : Bool
      @mutex.synchronize { @running }
    end

    def request_stop : Nil
      @mutex.synchronize { @stop_requested = true }
    end

    def start(sentences : Array(String), speaker_id : Int32, rate : Float64, output_path : String, on_status : Proc(String, Nil), on_finish : Proc(AudioExportResult, String, Nil)) : Bool
      export_sentences = @mutex.synchronize do
        return false if @running
        @running = true
        @stop_requested = false
        sentences.dup
      end

      VOVX.log_event("export.start speaker=#{speaker_id} rate=#{rate} sentences=#{export_sentences.size} path=#{output_path}")
      @context.spawn(name: "vovx-audio-export") do
        export_to_file(export_sentences, speaker_id, rate, output_path, on_status, on_finish)
      end
      true
    rescue ex
      finish(AudioExportResult::Failure, "保存ワーカー起動失敗: #{ex.message}", on_finish)
      true
    end

    private def export_to_file(sentences : Array(String), speaker_id : Int32, rate : Float64, output_path : String, on_status : Proc(String, Nil), on_finish : Proc(AudioExportResult, String, Nil)) : Nil
      tmp_path = "#{output_path}.tmp"
      writer = nil

      begin
        File.delete?(tmp_path)
        writer = WavWriter.new(tmp_path)

        sentences.each_with_index do |sentence, i|
          if stop_requested?
            finish(AudioExportResult::Cancelled, "保存を中断しました", on_finish)
            return
          end

          queue_status(on_status, "保存用に合成中 #{i + 1}/#{sentences.size}")
          wav = VOVX.synthesize(sentence, speaker_id, rate)
          begin
            writer.append_file(wav.path)
          ensure
            wav.close
            File.delete?(wav.path)
          end
        end

        writer.close
        writer = nil
        File.rename(tmp_path, output_path)
        VOVX.log_event("export.done path=#{output_path}")
        finish(AudioExportResult::Success, output_path, on_finish)
      rescue ex
        VOVX.log_event("export.error message=#{ex.message}")
        finish(AudioExportResult::Failure, "保存に失敗しました: #{ex.message}", on_finish)
      ensure
        begin
          writer.try &.close
        rescue
        end
        File.delete?(tmp_path)
      end
    end

    private def finish(result : AudioExportResult, message : String, on_finish : Proc(AudioExportResult, String, Nil)) : Nil
      @mutex.synchronize do
        @running = false
        @stop_requested = false
      end

      UIng.queue_main do
        on_finish.call(result, message)
      end
    end

    private def stop_requested? : Bool
      @mutex.synchronize { @stop_requested }
    end

    private def queue_status(on_status : Proc(String, Nil), message : String) : Nil
      UIng.queue_main do
        on_status.call(message)
      end
    end
  end
end

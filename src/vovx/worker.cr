require "json"
require "raudio"

module VOVX
  private class WorkerRequest
    include JSON::Serializable

    getter sentences : Array(String)
    getter speaker_id : Int32
    getter rate : Float64
  end

  def self.run_worker(input : IO = STDIN) : Nil
    stop_requested = false
    Process.on_terminate do
      stop_requested = true
    end

    request = WorkerRequest.from_json(input.gets_to_end)
    log_event("worker.input sentences=#{request.sentences.size} speaker=#{request.speaker_id} rate=#{request.rate}")

    ensure_worker_audio_device
    interrupted = play_worker_sentences(request, -> { stop_requested })
    Process.exit(interrupted ? 130 : 0)
  rescue ex
    log_event("worker.fatal message=#{ex.message}")
    Process.exit(1)
  ensure
    close_worker_audio_device
  end

  private def self.ensure_worker_audio_device : Nil
    Raudio::AudioDevice.init
    log_event("worker.audio_device.ready=#{Raudio::AudioDevice.ready?}")
  rescue ex
    log_event("worker.audio_device.init_failed message=#{ex.message}")
  end

  private def self.close_worker_audio_device : Nil
    Raudio::AudioDevice.close
    log_event("worker.audio_device.closed")
  rescue
  end

  private def self.play_worker_sentences(request : WorkerRequest, stop_requested : Proc(Bool)) : Bool
    request.sentences.each_with_index do |sentence, i|
      return true if stop_requested.call

      log_event("worker.synthesize index=#{i + 1}/#{request.sentences.size}")
      wav = synthesize(sentence, request.speaker_id, request.rate)
      begin
        return true if stop_requested.call

        log_event("worker.play index=#{i + 1}/#{request.sentences.size} path=#{wav.path}")
        play_worker_wav(wav.path, stop_requested)
      ensure
        wav.close
        File.delete?(wav.path)
        log_event("worker.cleanup index=#{i + 1}")
      end
    end

    stop_requested.call
  end

  private def self.play_worker_wav(path : String, stop_requested : Proc(Bool)) : Nil
    sound = Raudio::Sound.load(path)
    begin
      sound.play
      while sound.playing?
        if stop_requested.call
          sound.stop
          break
        end
        sleep 10.milliseconds
      end
    ensure
      sound.release
    end
  end
end

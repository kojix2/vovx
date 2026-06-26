require "json"

module VOVX
  private class WorkerPlaybackProcess
    enum Result
      Running
      Finished
      Interrupted
    end

    getter? stop_requested = false

    @process : Process?
    @pid : Int32?

    def initialize
      @process = nil
      @pid = nil
    end

    def running? : Bool
      !@pid.nil?
    end

    def start(sentences : Array(String), speaker_id : Int32, rate : Float64) : Bool
      return false if running?

      helper = worker_executable_path
      payload = {
        "sentences"  => sentences,
        "speaker_id" => speaker_id,
        "rate"       => rate,
      }.to_json

      process = Process.new(
        helper,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
      process.input.print(payload)
      process.input.close

      @process = process
      @pid = process.pid.to_i32
      @stop_requested = false
      VOVX.log_event("worker.start pid=#{@pid} path=#{helper}")
      true
    rescue ex
      VOVX.log_event("worker.start_failed message=#{ex.message}")
      cleanup_process
      false
    end

    def request_stop : Nil
      return unless process = @process

      @stop_requested = true
      VOVX.log_event("worker.stop_requested pid=#{@pid}")
      process.terminate(graceful: true)
    rescue ex
      VOVX.log_event("worker.stop_failed message=#{ex.message}")
    end

    def poll : Result
      pid = @pid
      return Result::Interrupted if pid.nil? && stop_requested?
      return Result::Finished if pid.nil?

      status = 0
      waited = LibC.waitpid(pid, pointerof(status), LibC::WNOHANG)
      case waited
      when 0
        Result::Running
      when pid
        VOVX.log_event("worker.finished pid=#{pid} status=#{status}")
        cleanup_process
        stop_requested? || status != 0 ? Result::Interrupted : Result::Finished
      else
        VOVX.log_event("worker.waitpid_failed pid=#{pid}")
        cleanup_process
        Result::Interrupted
      end
    end

    private def cleanup_process : Nil
      @process.try &.close
      @process = nil
      @pid = nil
    rescue ex
      VOVX.log_event("worker.cleanup_failed message=#{ex.message}")
    ensure
      @process = nil
      @pid = nil
    end

    private def worker_executable_path : String
      executable = Process.executable_path || PROGRAM_NAME
      directory = File.dirname(executable)
      bundled = File.join(directory, "vovx-worker")
      return bundled if executable_file?(bundled)

      local = File.join(Dir.current, "bin", "vovx-worker")
      return local if executable_file?(local)

      "vovx-worker"
    end

    private def executable_file?(path : String) : Bool
      info = File.info?(path)
      return false if info.nil? || !info.type.file?

      permissions = info.permissions
      permissions.owner_execute? || permissions.group_execute? || permissions.other_execute?
    end
  end
end

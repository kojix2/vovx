require "../worker_helper"

private def channel_empty?(channel : Channel(T)) : Bool forall T
  select
  when channel.receive
    false
  else
    true
  end
end

private class TestPlayback < VOVX::PlaybackController
  getter callbacks = Channel(Proc(Nil)).new(128)
  getter files = Channel(File).new(128)

  def initialize(@synthesis : Proc(String, VOVX::CancellationToken, File), @play : Proc(VOVX::CancellationToken, Nil))
  end

  protected def synthesize(sentence : String, speaker_id : Int32, rate : Float64, cancellation : VOVX::CancellationToken) : File
    file = @synthesis.call(sentence, cancellation)
    @files.send(file)
    file
  end

  protected def play_wav(path : String, cancellation : VOVX::CancellationToken) : Nil
    @play.call(cancellation)
  end

  protected def dispatch(&callback : -> Nil) : Nil
    @callbacks.send(callback)
  end
end

private class TestExporter < VOVX::AudioExporter
  getter callbacks = Channel(Proc(Nil)).new(128)
  getter files = Channel(File).new(128)

  def initialize(@synthesis : Proc(String, VOVX::CancellationToken, File))
  end

  protected def synthesize(sentence : String, speaker_id : Int32, rate : Float64, cancellation : VOVX::CancellationToken) : File
    file = @synthesis.call(sentence, cancellation)
    @files.send(file)
    file
  end

  protected def dispatch(&callback : -> Nil) : Nil
    @callbacks.send(callback)
  end
end

private def finish_playback(controller : TestPlayback, sentences : Array(String), finished : Channel(Bool)) : Nil
  controller.start(sentences, 1, 1.0, ->(_message : String) { }, ->(interrupted : Bool) { finished.send(interrupted) }).should be_true
end

private def pump_until_idle(worker : TestPlayback | TestExporter) : Nil
  deadline = Time.instant + 3.seconds
  loop do
    select
    when callback = worker.callbacks.receive
      callback.call
    else
      break unless worker.running?
      sleep 5.milliseconds
    end
    raise "worker timed out" if Time.instant > deadline
  end
  # running? becomes false only after the final callback was queued.
  loop do
    select
    when callback = worker.callbacks.receive
      callback.call
    else
      break
    end
  end
end

private def assert_removed(file : File) : Nil
  file.closed?.should be_true
  File.exists?(file.path).should be_false
end

describe VOVX::PlaybackController do
  it "does not report synthesis failure as successful playback" do
    controller = TestPlayback.new(->(sentence : String, _c : VOVX::CancellationToken) : File {
      raise "synthesis failed" if sentence == "one"
      File.tempfile("vovx_spec_", ".wav")
    }, ->(_c : VOVX::CancellationToken) { })
    finished = Channel(Bool).new(2)
    finish_playback(controller, ["one"], finished)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_true
    controller.error_message.should eq("合成失敗: synthesis failed")
    channel_empty?(finished).should be_true
    finish_playback(controller, ["retry"], finished)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_false
    controller.error_message.should be_nil
    assert_removed(receive_with_timeout(controller.files))
  end

  it "cleans successful files and reports success exactly once" do
    controller = TestPlayback.new(->(_s : String, _c : VOVX::CancellationToken) { File.tempfile("vovx_spec_", ".wav") }, ->(_c : VOVX::CancellationToken) { })
    finished = Channel(Bool).new(2)
    finish_playback(controller, ["one", "two"], finished)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_false
    controller.error_message.should be_nil
    2.times { assert_removed(receive_with_timeout(controller.files)) }
    channel_empty?(finished).should be_true
  end

  it "cleans playing, buffered, and blocked-sender WAVs on stop" do
    playing = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    controller = TestPlayback.new(->(_s : String, _c : VOVX::CancellationToken) { File.tempfile("vovx_spec_", ".wav") }, ->(_c : VOVX::CancellationToken) { playing.send(nil); release.receive })
    finished = Channel(Bool).new(2)
    finish_playback(controller, ["one", "two", "three", "four", "five"], finished)
    receive_with_timeout(playing)
    files = Array.new(4) { receive_with_timeout(controller.files) }
    controller.request_stop
    release.send(nil)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_true
    files.each { |file| assert_removed(file) }
    channel_empty?(controller.files).should be_true
  ensure
    controller.try &.request_stop
    release.try &.close
  end

  it "stays running until an in-flight synthesis has cleaned up" do
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    controller = TestPlayback.new(->(sentence : String, _c : VOVX::CancellationToken) {
      if sentence == "one"
        entered.send(nil)
        release.receive
      end
      File.tempfile("vovx_spec_", ".wav")
    }, ->(_c : VOVX::CancellationToken) { })
    finished = Channel(Bool).new(2)
    finish_playback(controller, ["one"], finished)
    receive_with_timeout(entered)
    controller.request_stop
    controller.running?.should be_true
    controller.start(["another"], 1, 1.0, ->(_m : String) { }, ->(_b : Bool) { }).should be_false
    release.send(nil)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_true
    assert_removed(receive_with_timeout(controller.files))
    finish_playback(controller, ["another"], finished)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_false
    assert_removed(receive_with_timeout(controller.files))
  ensure
    controller.try &.request_stop
    release.try &.close
  end

  it "cleans queued files after a playback error" do
    controller = TestPlayback.new(->(_s : String, _c : VOVX::CancellationToken) { File.tempfile("vovx_spec_", ".wav") }, ->(_c : VOVX::CancellationToken) { raise "audio failed" })
    finished = Channel(Bool).new(2)
    finish_playback(controller, ["one", "two", "three", "four"], finished)
    pump_until_idle(controller)
    receive_with_timeout(finished).should be_true
    controller.error_message.should eq("再生失敗: audio failed")
    loop do
      select
      when file = controller.files.receive
        assert_removed(file)
      else
        break
      end
    end
  end
end

describe VOVX::AudioExporter do
  it "writes merged audio and leaves unrelated temporary files untouched" do
    temporary = File.tempfile("vovx_export_spec_")
    directory = temporary.path + "_dir"
    temporary.close
    Dir.mkdir(directory)
    output = File.join(directory, "output.wav")
    File.write(output + ".tmp", "unrelated file")
    exporter = TestExporter.new(->(_s : String, _c : VOVX::CancellationToken) {
      io = IO::Memory.new
      io.write("RIFF".to_slice)
      io.write_bytes(38_u32, IO::ByteFormat::LittleEndian)
      io.write("WAVEfmt ".to_slice)
      io.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(24_000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(48_000_u32, IO::ByteFormat::LittleEndian)
      io.write_bytes(2_u16, IO::ByteFormat::LittleEndian)
      io.write_bytes(16_u16, IO::ByteFormat::LittleEndian)
      io.write("data".to_slice)
      io.write_bytes(2_u32, IO::ByteFormat::LittleEndian)
      io.write(UInt8.slice(1, 2))
      file = File.tempfile("vovx_spec_", ".wav")
      file.write(io.to_slice)
      file.flush
      file
    })
    finished = Channel(VOVX::AudioExportResult).new(2)
    exporter.start(["one", "two"], 1, 1.0, output, ->(_s : String) { }, ->(result : VOVX::AudioExportResult, _m : String) { finished.send(result) })
    pump_until_idle(exporter)
    receive_with_timeout(finished).should eq(VOVX::AudioExportResult::Success)
    bytes = File.read(output).to_slice
    VOVX::WavWriter.parse(bytes).data_size.should eq(4)
    bytes[44, 4].to_a.should eq([1_u8, 2_u8, 1_u8, 2_u8])
    File.read(output + ".tmp").should eq("unrelated file")
    Dir.children(directory).sort.should eq(["output.wav", "output.wav.tmp"])
    2.times { assert_removed(receive_with_timeout(exporter.files)) }
  ensure
    if directory
      Dir.each_child(directory) { |name| File.delete?(File.join(directory, name)) }
      Dir.delete(directory)
    end
    File.delete?(temporary.path) if temporary
  end

  it "honors cancellation during the last sentence without replacing the target" do
    target = File.tempfile("vovx_export_spec_", ".wav")
    target.print("existing audio")
    target.close
    exporter = TestExporter.new(->(_s : String, cancellation : VOVX::CancellationToken) { cancellation.cancel; File.tempfile("vovx_spec_", ".wav") })
    finished = Channel(VOVX::AudioExportResult).new(2)
    exporter.start(["last"], 1, 1.0, target.path, ->(_s : String) { }, ->(result : VOVX::AudioExportResult, _m : String) { finished.send(result) }).should be_true
    pump_until_idle(exporter)
    receive_with_timeout(finished).should eq(VOVX::AudioExportResult::Cancelled)
    File.read(target.path).should eq("existing audio")
    assert_removed(receive_with_timeout(exporter.files))
    channel_empty?(finished).should be_true
  ensure
    File.delete?(target.path) if target
  end

  it "cancels an in-flight export promptly" do
    target = File.tempfile("vovx_export_spec_", ".wav")
    target.close
    entered = Channel(Nil).new(1)
    exporter = TestExporter.new(->(_s : String, cancellation : VOVX::CancellationToken) { entered.send(nil); cancellation.pause(120.seconds); File.tempfile("vovx_spec_", ".wav") })
    finished = Channel(VOVX::AudioExportResult).new(2)
    exporter.start(["one"], 1, 1.0, target.path, ->(_s : String) { }, ->(result : VOVX::AudioExportResult, _m : String) { finished.send(result) })
    receive_with_timeout(entered)
    exporter.request_stop
    pump_until_idle(exporter)
    receive_with_timeout(finished).should eq(VOVX::AudioExportResult::Cancelled)
    File.size(target.path).should eq(0)
  ensure
    exporter.try &.request_stop
    File.delete?(target.path) if target
  end

  it "preserves the existing target on synthesis failure" do
    target = File.tempfile("vovx_export_spec_", ".wav")
    target.print("original")
    target.close
    exporter = TestExporter.new(->(_s : String, _c : VOVX::CancellationToken) : File { raise "API failed" })
    finished = Channel(VOVX::AudioExportResult).new(2)
    exporter.start(["one"], 1, 1.0, target.path, ->(_s : String) { }, ->(result : VOVX::AudioExportResult, _m : String) { finished.send(result) })
    pump_until_idle(exporter)
    receive_with_timeout(finished).should eq(VOVX::AudioExportResult::Failure)
    File.read(target.path).should eq("original")
  ensure
    File.delete?(target.path) if target
  end
end

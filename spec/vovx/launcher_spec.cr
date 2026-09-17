require "../spec_helper"

module VOVX
  def self.test_launch(command : String, args : Array(String), startup_grace : Time::Span = 200.milliseconds) : Bool
    launch_background(command, args, "spec", startup_grace)
  end

  def self.test_linux_launch : Bool
    start_voicevox_application_linux
  end

  def self.test_empty_styles : Array(VoiceStyleOption)
    AppState.new(Array(String).new, Array(VoiceStyleOption).new, DEFAULT_RATE, UserSettings.new).styles
  end
end

describe "VOICEVOX launcher" do
  it "rejects a command that exits unsuccessfully" do
    VOVX.test_launch("sh", ["-c", "exit 1"]).should be_false
  end

  it "checks dispatcher exit status even after the startup grace period" do
    VOVX.test_launch("sh", ["-c", "sleep 0.3; exit 1"], startup_grace: 3.seconds).should be_false
  end

  it "does not wait for a long-running application to exit" do
    started = Time.instant
    VOVX.test_launch("sh", ["-c", "sleep 1"]).should be_true
    (Time.instant - started).should be < 800.milliseconds
  end

  it "tries later candidates when desktop entries and flatpak fail" do
    temporary = File.tempfile("vovx_launcher_spec_")
    directory = temporary.path + "_dir"
    temporary.close
    Dir.mkdir(directory)
    commands = ["gtk-launch", "flatpak", "VOICEVOX"]
    commands.each do |name|
      File.write(File.join(directory, name), "#!/bin/sh\nprintf '%s\\n' '#{name}' >> '#{directory}/attempts'\nexit #{name == "VOICEVOX" ? 0 : 1}\n")
      File.chmod(File.join(directory, name), 0o700)
    end
    launcher_with_env("PATH", directory) do
      launcher_with_env("VOVX_VOICEVOX_COMMAND", nil) do
        VOVX.test_linux_launch.should be_true
      end
    end
    deadline = Time.instant + 3.seconds
    while File.read_lines(File.join(directory, "attempts")).size < 5
      raise "fallback command timed out" if Time.instant > deadline
      sleep 10.milliseconds
    end
    File.read_lines(File.join(directory, "attempts")).should eq(["gtk-launch", "gtk-launch", "gtk-launch", "flatpak", "VOICEVOX"])
  ensure
    if directory
      commands.try &.each { |name| File.delete?(File.join(directory, name)) }
      File.delete?(File.join(directory, "attempts"))
      Dir.delete(directory) if Dir.exists?(directory)
    end
    File.delete?(temporary.path) if temporary
  end

  it "provides a default style when the initial style list is empty" do
    VOVX.test_empty_styles.should eq([VOVX.default_voice_style])
  end
end

private def launcher_with_env(key : String, value : String?, &)
  original = ENV[key]?
  if value
    ENV[key] = value
  else
    ENV.delete(key)
  end
  yield
ensure
  if original
    ENV[key] = original
  else
    ENV.delete(key)
  end
end

module VOVX
  # OS ごとの標準的な方法で VOICEVOX アプリを起動する。
  def self.start_voicevox_application : Bool
    {% if flag?(:darwin) %}
      start_voicevox_application_macos
    {% elsif flag?(:linux) %}
      start_voicevox_application_linux
    {% else %}
      log_event("voicevox_start.unsupported_platform")
      false
    {% end %}
  end

  # アプリ起動直後は Engine の待受開始まで少し時間がかかるため、短くポーリングする。
  def self.wait_for_voicevox_engine(max_attempts : Int32 = 30, interval : Time::Span = 1.second, on_attempt : Proc(Int32, Int32, Nil)? = nil) : Bool
    max_attempts.times do |attempt|
      return true if voicevox_engine_running?

      current_attempt = attempt + 1
      log_event("voicevox_start.wait attempt=#{current_attempt}/#{max_attempts}")
      on_attempt.try &.call(current_attempt, max_attempts)
      sleep interval
    end

    false
  end

  # macOS の Launch Services 経由で VOICEVOX アプリを起動する。
  private def self.start_voicevox_application_macos : Bool
    process = Process.new(
      "open",
      ["-g", "-j", "-a", VOICEVOX_APP],
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    process.close
    true
  rescue ex
    log_event("voicevox_start.open_failed message=#{ex.message}")
    false
  end

  # Linux ではインストール形態が分かれるため、明示コマンド、desktop entry、
  # PATH 上の実行ファイルを順に試す。
  private def self.start_voicevox_application_linux : Bool
    return true if launch_custom_voicevox_command
    return true if launch_voicevox_desktop_entry
    return true if launch_voicevox_flatpak
    return true if launch_voicevox_from_path

    log_event("voicevox_start.linux_no_candidate")
    false
  rescue ex
    log_event("voicevox_start.linux_failed message=#{ex.message}")
    false
  end

  private def self.launch_custom_voicevox_command : Bool
    command = ENV["VOVX_VOICEVOX_COMMAND"]?.try &.strip
    return false if command.nil?

    if command.empty?
      log_event("voicevox_start.custom_command_empty")
      false
    elsif launch_shell_background(command)
      log_event("voicevox_start.custom_command")
      true
    else
      false
    end
  end

  private def self.launch_voicevox_desktop_entry : Bool
    if Process.find_executable("gtk-launch")
      ["voicevox", "VOICEVOX", "jp.hiroshiba.voicevox"].each do |desktop_id|
        return true if launch_background("gtk-launch", [desktop_id], "gtk_launch.#{desktop_id}")
      end
    end

    desktop_files.each do |desktop_file|
      next unless File.exists?(desktop_file)

      return true if launch_background("xdg-open", [desktop_file], "xdg_open.#{File.basename(desktop_file)}")
    end

    false
  end

  private def self.launch_voicevox_flatpak : Bool
    launch_background("flatpak", ["run", "jp.hiroshiba.voicevox"], "flatpak")
  end

  private def self.launch_voicevox_from_path : Bool
    ["VOICEVOX", "voicevox"].each do |executable|
      next unless Process.find_executable(executable)

      return true if launch_background(executable, [] of String, "path.#{executable}")
    end

    false
  end

  private def self.desktop_files : Array(String)
    home = ENV["HOME"]?
    data_dirs = (ENV["XDG_DATA_DIRS"]? || "/usr/local/share:/usr/share").split(":")
    application_dirs = data_dirs.map { |dir| File.join(dir, "applications") }
    if home
      application_dirs.unshift(File.join(home, ".local", "share", "applications"))
    end

    filenames = ["voicevox.desktop", "VOICEVOX.desktop", "jp.hiroshiba.voicevox.desktop"]
    application_dirs.flat_map do |dir|
      filenames.map { |filename| File.join(dir, filename) }
    end
  end

  private def self.launch_background(command : String, args : Array(String), label : String) : Bool
    return false unless Process.find_executable(command)

    process = Process.new(
      command,
      args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    process.close
    true
  rescue ex
    log_event("voicevox_start.#{label}_failed message=#{ex.message}")
    false
  end

  private def self.launch_shell_background(command : String) : Bool
    process = Process.new(
      "sh",
      ["-c", "exec #{command}"],
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    process.close
    true
  rescue ex
    log_event("voicevox_start.custom_command_failed message=#{ex.message}")
    false
  end
end

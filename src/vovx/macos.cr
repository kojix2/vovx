require "uing"

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
    if command = ENV["VOVX_VOICEVOX_COMMAND"]?
      command = command.strip
      if command.empty?
        log_event("voicevox_start.custom_command_empty")
      elsif launch_shell_background(command)
        log_event("voicevox_start.custom_command")
        return true
      end
    end

    desktop_ids = ["voicevox", "VOICEVOX", "jp.hiroshiba.voicevox"]
    if Process.find_executable("gtk-launch")
      desktop_ids.each do |desktop_id|
        return true if launch_background("gtk-launch", [desktop_id], "gtk_launch.#{desktop_id}")
      end
    end

    desktop_files.each do |desktop_file|
      next unless File.exists?(desktop_file)
      return true if launch_background("xdg-open", [desktop_file], "xdg_open.#{File.basename(desktop_file)}")
    end

    if Process.find_executable("flatpak")
      return true if launch_background("flatpak", ["run", "jp.hiroshiba.voicevox"], "flatpak")
    end

    ["VOICEVOX", "voicevox"].each do |command|
      next unless Process.find_executable(command)
      return true if launch_background(command, [] of String, "path.#{command}")
    end

    log_event("voicevox_start.linux_no_candidate")
    false
  rescue ex
    log_event("voicevox_start.linux_failed message=#{ex.message}")
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

  # macOS のデスクトップ境界を AppleScript で取得する。
  # 失敗時は nil を返し、呼び出し側は中央寄せを諦めて通常表示へ戻す。
  def self.macos_screen_bounds : {Int32, Int32, Int32, Int32}?
    {% unless flag?(:darwin) %}
      return nil
    {% end %}

    output = IO::Memory.new
    status = Process.run(
      "osascript",
      ["-e", "tell application \"Finder\" to get bounds of window of desktop"],
      output: output,
      error: Process::Redirect::Close
    )
    return nil unless status.success?

    parts = output.to_s.strip.split(",").map(&.strip)
    return nil unless parts.size == 4

    left = parts[0].to_i?
    top = parts[1].to_i?
    right = parts[2].to_i?
    bottom = parts[3].to_i?
    return nil if left.nil? || top.nil? || right.nil? || bottom.nil?

    {left, top, right, bottom}
  rescue
    nil
  end

  # libui には環境横断の確実な中央寄せ API がないため、macOS では画面境界から手動計算する。
  def self.center_window_on_main_screen(window : UIng::Window, width : Int32, height : Int32) : Nil
    bounds = macos_screen_bounds
    return if bounds.nil?

    left, top, right, bottom = bounds
    x = (left + right - width) // 2
    y = (top + bottom - height) // 2
    window.set_position(x.to_i32, y.to_i32)
  end

  # パイプ起動時でも小さな操作ウィンドウを前面に出すための補助。
  def self.focus_current_process : Nil
    {% unless flag?(:darwin) %}
      return
    {% end %}

    script = "tell application \"System Events\" to tell (first process whose unix id is #{Process.pid}) to set frontmost to true"
    Process.run("osascript", ["-e", script], output: Process::Redirect::Close, error: Process::Redirect::Close)
  rescue
    # 前面化できない環境でも、ウィンドウ自体は通常通り表示できる。
  end
end

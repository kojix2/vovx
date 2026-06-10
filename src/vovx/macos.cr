require "uing"
require "file_utils"

module VOVX
  SERVICE_WORKFLOW_NAME = "VOVX.workflow"

  {% if flag?(:darwin) %}
    lib CoreGraphics
      struct CGPoint
        x : LibC::Double
        y : LibC::Double
      end

      struct CGSize
        width : LibC::Double
        height : LibC::Double
      end

      struct CGRect
        origin : CGPoint
        size : CGSize
      end

      fun main_display_id = CGMainDisplayID : UInt32
      fun display_bounds = CGDisplayBounds(display : UInt32) : CGRect
    end
  {% end %}

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

  # macOS のメインディスプレイ境界を CoreGraphics で取得する。
  # AppKit の main loop 前に Crystal の main fiber をブロックしないよう、外部プロセスは使わない。
  def self.macos_screen_bounds : {Int32, Int32, Int32, Int32}?
    {% unless flag?(:darwin) %}
      return nil
    {% else %}
      bounds = CoreGraphics.display_bounds(CoreGraphics.main_display_id)
      left = bounds.origin.x.to_i
      top = bounds.origin.y.to_i
      right = (bounds.origin.x + bounds.size.width).to_i
      bottom = (bounds.origin.y + bounds.size.height).to_i
      {left, top, right, bottom}
    {% end %}
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
    process = Process.new(
      "osascript",
      ["-e", script],
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    process.close
  rescue
    # 前面化できない環境でも、ウィンドウ自体は通常通り表示できる。
  end

  def self.install_service_workflow : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューへの追加は macOS でのみ利用できます。"}
    {% end %}

    source = service_workflow_source_path
    unless valid_service_workflow?(source)
      log_event("service.install.source_missing path=#{source}")
      return {false, "同梱されたサービス定義が見つかりませんでした。\n#{source}"}
    end

    destination = service_workflow_destination_path
    services_dir = service_workflow_directory_path
    FileUtils.mkdir_p(services_dir)
    unless Dir.exists?(services_dir)
      log_event("service.install.services_dir_missing path=#{services_dir}")
      return {false, "サービス用ディレクトリを作成できませんでした。\n#{services_dir}"}
    end

    FileUtils.rm_rf(destination) if Dir.exists?(destination) || File.exists?(destination)
    FileUtils.cp_r(source, destination)
    unless valid_service_workflow?(destination)
      log_event("service.install.verify_failed path=#{destination}")
      return {false, "サービス定義をコピーしましたが、内容を確認できませんでした。\n#{destination}"}
    end

    log_event("service.install.done path=#{destination}")
    {true, "サービスメニューに追加しました。\n#{destination}\n\n表示されない場合は、呼び出し元アプリを再起動してください。"}
  rescue ex
    log_event("service.install.failed message=#{ex.message}")
    {false, "サービスメニューへの追加に失敗しました。\n#{ex.message}"}
  end

  def self.uninstall_service_workflow : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューからの削除は macOS でのみ利用できます。"}
    {% end %}

    destination = service_workflow_destination_path
    unless Dir.exists?(destination) || File.exists?(destination)
      return {true, "サービスメニューには追加されていません。"}
    end

    FileUtils.rm_rf(destination)
    log_event("service.uninstall.done path=#{destination}")
    {true, "サービスメニューから削除しました。\n#{destination}\n\n表示が残る場合は、呼び出し元アプリを再起動してください。"}
  rescue ex
    log_event("service.uninstall.failed message=#{ex.message}")
    {false, "サービスメニューからの削除に失敗しました。\n#{ex.message}"}
  end

  def self.open_service_workflow_directory : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューのディレクトリは macOS でのみ開けます。"}
    {% end %}

    services_dir = service_workflow_directory_path
    FileUtils.mkdir_p(services_dir)
    status = Process.run(
      "open",
      [services_dir],
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    if status.success?
      log_event("service.open_directory.done path=#{services_dir}")
      {true, "サービスメニューのディレクトリを開きました。\n#{services_dir}"}
    else
      log_event("service.open_directory.failed path=#{services_dir} status=#{status.exit_code}")
      {false, "サービスメニューのディレクトリを開けませんでした。\n#{services_dir}"}
    end
  rescue ex
    log_event("service.open_directory.failed message=#{ex.message}")
    {false, "サービスメニューのディレクトリを開けませんでした。\n#{ex.message}"}
  end

  private def self.service_workflow_source_path : String
    bundled_path = Paths.bundled_resource_path(SERVICE_WORKFLOW_NAME)
    return bundled_path if Dir.exists?(bundled_path)

    Paths.development_resource_path("macos", SERVICE_WORKFLOW_NAME)
  end

  private def self.service_workflow_directory_path : String
    Paths.macos_services_dir
  end

  private def self.service_workflow_destination_path : String
    File.join(service_workflow_directory_path, SERVICE_WORKFLOW_NAME)
  end

  private def self.valid_service_workflow?(path : String) : Bool
    Dir.exists?(path) &&
      File.exists?(File.join(path, "Contents", "Info.plist")) &&
      File.exists?(File.join(path, "Contents", "document.wflow"))
  end
end

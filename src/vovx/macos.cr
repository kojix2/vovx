require "uing"

module VOVX
  # macOS のデスクトップ境界を AppleScript で取得する。
  # 失敗時は nil を返し、呼び出し側は中央寄せを諦めて通常表示へ戻す。
  def self.macos_screen_bounds : {Int32, Int32, Int32, Int32}?
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
    script = "tell application \"System Events\" to tell (first process whose unix id is #{Process.pid}) to set frontmost to true"
    Process.run("osascript", ["-e", script], output: Process::Redirect::Close, error: Process::Redirect::Close)
  rescue
    # 前面化できない環境でも、ウィンドウ自体は通常通り表示できる。
  end
end

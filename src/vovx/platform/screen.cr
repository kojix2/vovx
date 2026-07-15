require "uing"

module VOVX
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
end

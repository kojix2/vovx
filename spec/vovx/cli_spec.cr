require "../spec_helper"

private class TtyInput < IO
  def tty? : Bool
    true
  end

  def read(slice : Bytes) : Int32
    raise "TTY input should not be read"
  end

  def write(slice : Bytes) : Nil
  end
end

describe "VOVX CLI" do
  describe ".read_cli_input" do
    it "reads piped input" do
      VOVX.read_cli_input(IO::Memory.new("読み上げる文章です。")).should eq("読み上げる文章です。")
    end

    it "does not block waiting for terminal input" do
      VOVX.read_cli_input(TtyInput.new).should eq("")
    end
  end
end

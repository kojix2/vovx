require "log"

module VOVX
  LOG_PATH = Paths.log_path

  # GUI アプリでは標準エラーが見えないことが多いので、通常はファイルへログを残す。
  # ファイルを開けない環境でもアプリ本体は動くように STDERR へフォールバックする。
  LOG_IO = begin
    Dir.mkdir_p(File.dirname(LOG_PATH))
    File.open(LOG_PATH, "a")
  rescue
    STDERR
  end

  LOG_BACKEND = Log::IOBackend.new(LOG_IO)
  Log.setup(:info, LOG_BACKEND)
  LOGGER = Log.for("vovx")

  # ログ出力は診断用であり、音声再生の成功条件には含めない。
  def self.log_event(message : String) : Nil
    LOGGER.info { message }
  rescue
    # ログ出力の失敗で再生処理を止めない。
  end
end

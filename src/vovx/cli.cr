module VOVX
  # CLI 入口。標準入力をすべて読み取り、空でなければ GUI を起動する。
  # input/error を差し替え可能にしておくことで、将来の CLI テストを組みやすくしている。
  def self.run_cli(input : IO = STDIN, error : IO = STDERR) : Nil
    text = input.gets_to_end
    sentences = split_sentences(text)
    log_event("input.received chars=#{text.size} sentences=#{sentences.size} log_path=#{LOG_PATH}")

    if sentences.empty?
      error.puts "No input text."
      log_event("input.empty")
      exit
    end

    unless voicevox_engine_running?
      error.puts "VOICEVOX Engine is not running at #{ENGINE_URL}. Start VOICEVOX, then try again."
      log_event("voicevox_engine.not_running")
      exit 1
    end

    styles = fetch_voice_styles
    run_app(sentences, styles)
  end
end

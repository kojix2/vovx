require "easyclip"

module VOVX
  # CLI 入口。標準入力をすべて読み取り、空でなければ GUI を起動する。
  # input/error を差し替え可能にしておくことで、将来の CLI テストを組みやすくしている。
  def self.run_cli(input : IO = STDIN, error : IO = STDERR) : Nil
    text = input.gets_to_end
    sentences = split_sentences(text)
    log_event("input.received chars=#{text.size} sentences=#{sentences.size} log_path=#{LOG_PATH}")

    if sentences.empty?
      text = clipboard_text
      sentences = split_sentences(text)
      log_event("input.clipboard chars=#{text.size} sentences=#{sentences.size}")
    end

    if sentences.empty?
      error.puts "No input text."
      log_event("input.empty")
      exit
    end

    run_app(sentences, [default_voice_style])
  end

  private def self.clipboard_text : String
    EasyClip.paste
  rescue ex
    log_event("input.clipboard_failed message=#{ex.message}")
    ""
  end
end

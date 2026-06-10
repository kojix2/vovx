require "easyclip"

module VOVX
  # CLI 入口。標準入力をすべて読み取り、GUI を起動する。
  # input を差し替え可能にしておくことで、将来の CLI テストを組みやすくしている。
  def self.run_cli(input : IO = STDIN) : Nil
    text = read_cli_input(input)
    sentences = split_sentences(text)
    log_event("input.received chars=#{text.size} sentences=#{sentences.size} log_path=#{LOG_PATH}")

    if sentences.empty?
      text = clipboard_text
      sentences = split_sentences(text)
      log_event("input.clipboard chars=#{text.size} sentences=#{sentences.size}")
    end

    if sentences.empty?
      log_event("input.empty")
    end

    run_app(sentences, [default_voice_style])
  end

  def self.read_cli_input(input : IO) : String
    input.tty? ? "" : input.gets_to_end
  end

  private def self.clipboard_text : String
    EasyClip.paste
  rescue ex
    log_event("input.clipboard_failed message=#{ex.message}")
    ""
  end
end

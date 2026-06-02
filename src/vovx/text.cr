module VOVX
  # 標準入力から受け取った日本語テキストを、VOICEVOX に投げる単位へ分割する。
  # 句点・感嘆符・疑問符・改行を区切りにし、空白だけの断片は捨てる。
  def self.split_sentences(text : String) : Array(String)
    text
      .scan(/.+?(?:[\x{3002}\x{ff01}\x{ff1f}!?]+|\n+|$)/m)
      .map(&.[0].strip)
      .reject(&.empty?)
  end
end

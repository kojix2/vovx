module VOVX
  # GUI の声選択コンボボックスに表示する 1 項目。
  # label はユーザー向け表示名、speaker_id は VOICEVOX API に渡す数値 ID。
  record VoiceStyleOption, label : String, speaker_id : Int32

  # Engine から話者一覧を取得できなかった場合の最小フォールバック。
  def self.default_voice_style : VoiceStyleOption
    VoiceStyleOption.new("デフォルト", DEFAULT_SPEAKER)
  end
end

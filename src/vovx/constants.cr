module VOVX
  # VOICEVOX Engine の標準待受先。
  # 現状はローカル起動を前提にしているため、設定ファイル化はしていない。
  ENGINE_URL      = "http://localhost:50021"
  VOICEVOX_APP    = "VOICEVOX"
  REPOSITORY_URL  = {{ `git remote get-url origin`.chomp.stringify }}
  DEFAULT_SPEAKER =   1
  DEFAULT_RATE    = 1.5
  WINDOW_WIDTH    = 240
  WINDOW_HEIGHT   = 120
end

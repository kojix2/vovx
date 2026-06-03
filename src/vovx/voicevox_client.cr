require "http/client"
require "json"
require "uri/params"

module VOVX
  ENGINE_CONNECT_TIMEOUT = 1.second
  ENGINE_HEALTH_TIMEOUT  = 1.second
  ENGINE_READ_TIMEOUT    = 5.seconds
  ENGINE_SYNTH_TIMEOUT   = 120.seconds

  private def self.with_engine_client(read_timeout : Time::Span, & : HTTP::Client -> HTTP::Client::Response) : HTTP::Client::Response
    uri = URI.parse(ENGINE_URL)
    client = HTTP::Client.new(uri)
    client.connect_timeout = ENGINE_CONNECT_TIMEOUT
    client.read_timeout = read_timeout

    yield client
  ensure
    client.try &.close
  end

  private def self.engine_get(path : String, read_timeout : Time::Span = ENGINE_READ_TIMEOUT) : HTTP::Client::Response
    with_engine_client(read_timeout) do |client|
      client.get(path)
    end
  end

  private def self.engine_post(path : String, headers : HTTP::Headers, body : String? = nil, read_timeout : Time::Span = ENGINE_READ_TIMEOUT) : HTTP::Client::Response
    with_engine_client(read_timeout) do |client|
      client.post(path, headers: headers, body: body)
    end
  end

  # VOICEVOX Engine の HTTP 応答を確認し、失敗時は呼び出し元で扱いやすい例外にする。
  def self.ensure_success!(response : HTTP::Client::Response, endpoint : String) : Nil
    return if response.success?

    raise "VOICEVOX API error at #{endpoint}: #{response.status_code} #{response.body}"
  end

  # VOICEVOX Engine が起動しているかを軽量なエンドポイントで確認する。
  def self.voicevox_engine_running? : Bool
    response = engine_get("/version", read_timeout: ENGINE_HEALTH_TIMEOUT)
    response.success?
  rescue ex
    log_event("voicevox_engine.unavailable message=#{ex.message}")
    false
  end

  # /speakers の JSON から、読み上げに使える talk スタイルだけを抽出する。
  # sing など読み上げ用途ではないスタイルは GUI に出さない。
  def self.parse_voice_styles(body : String) : Array(VoiceStyleOption)
    speakers = JSON.parse(body).as_a
    styles = [] of VoiceStyleOption

    speakers.each do |speaker|
      speaker_hash = speaker.as_h
      character_name = speaker_hash["name"].as_s

      speaker_hash["styles"].as_a.each do |style|
        style_hash = style.as_h
        style_type = style_hash["type"]?.try(&.as_s?)
        next if style_type && style_type != "talk"

        style_name = style_hash["name"].as_s
        style_id = style_hash["id"].as_i
        label = "#{character_name}（#{style_name}）"
        styles << VoiceStyleOption.new(label, style_id)
      end
    end

    styles.empty? ? [default_voice_style] : styles
  end

  # 起動中の VOICEVOX Engine から話者一覧を取得する。
  # Engine 未起動でも UI は開けるように、取得失敗時はデフォルト話者へ落とす。
  def self.fetch_voice_styles : Array(VoiceStyleOption)
    response = engine_get("/speakers")
    ensure_success!(response, "/speakers")
    parse_voice_styles(response.body)
  rescue ex
    log_event("fetch_voice_styles.error message=#{ex.message}")
    [default_voice_style]
  end

  # 1 文を VOICEVOX Engine で合成し、一時 WAV ファイルとして返す。
  # 呼び出し側は再生後に close と削除を行う責務を持つ。
  def self.synthesize(sentence : String, speaker_id : Int32, rate : Float64) : File
    log_event("synthesize.start speaker=#{speaker_id} rate=#{rate} len=#{sentence.size}")

    query_params = URI::Params.encode({
      "text"    => sentence,
      "speaker" => speaker_id.to_s,
    })

    query_res = engine_post(
      "/audio_query?#{query_params}",
      headers: HTTP::Headers{"accept" => "application/json"}
    )
    ensure_success!(query_res, "/audio_query")

    # audio_query の応答 JSON に速度だけを上書きし、そのまま synthesis へ渡す。
    query_json = JSON.parse(query_res.body).as_h
    query_json["speedScale"] = JSON::Any.new(rate)

    synth_params = URI::Params.encode({
      "speaker" => speaker_id.to_s,
    })

    synth_res = engine_post(
      "/synthesis?#{synth_params}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: query_json.to_json,
      read_timeout: ENGINE_SYNTH_TIMEOUT
    )
    ensure_success!(synth_res, "/synthesis")

    file = File.tempfile("voicevox_", ".wav")
    file.write synth_res.body.to_slice
    file.flush
    log_event("synthesize.done speaker=#{speaker_id} path=#{file.path}")
    file
  end
end

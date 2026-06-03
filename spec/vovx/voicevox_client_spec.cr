require "../spec_helper"

describe VOVX do
  describe ".parse_voice_styles" do
    it "returns talk styles with character names in labels" do
      body = <<-JSON
        [
          {
            "name": "四国めたん",
            "styles": [
              {"name": "ノーマル", "id": 2, "type": "talk"},
              {"name": "歌", "id": 6000, "type": "sing"}
            ]
          },
          {
            "name": "ずんだもん",
            "styles": [
              {"name": "あまあま", "id": 1}
            ]
          }
        ]
        JSON
      styles = VOVX.parse_voice_styles(body)

      styles.should eq([
        VOVX::VoiceStyleOption.new("四国めたん（ノーマル）", 2),
        VOVX::VoiceStyleOption.new("ずんだもん（あまあま）", 1),
      ])
    end

    it "falls back to the default style when no talk styles exist" do
      body = <<-JSON
        [
          {
            "name": "歌唱専用",
            "styles": [
              {"name": "ソング", "id": 6000, "type": "sing"}
            ]
          }
        ]
        JSON
      styles = VOVX.parse_voice_styles(body)

      styles.should eq([VOVX.default_voice_style])
    end
  end

  describe ".ensure_success!" do
    it "does nothing for successful responses" do
      response = HTTP::Client::Response.new(200, "ok")

      VOVX.ensure_success!(response, "/ok").should be_nil
    end

    it "raises with endpoint and response details for failed responses" do
      response = HTTP::Client::Response.new(500, "boom")

      expect_raises(Exception, "VOICEVOX API error at /broken: 500 boom") do
        VOVX.ensure_success!(response, "/broken")
      end
    end
  end
end

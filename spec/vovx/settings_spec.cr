require "../spec_helper"

private def settings_spec_path : String
  File.join(Dir.tempdir, "vovx-settings-spec-#{Time.utc.to_unix_ms}-#{rand(1_000_000)}", "config.json")
end

describe VOVX::UserSettings do
  describe "persistence" do
    it "saves and loads speaker and rate" do
      path = settings_spec_path

      VOVX.save_user_settings(VOVX::UserSettings.new(speaker_id: 3, rate: 1.25, auto_play: true, quit_after_playback: false), path)
      settings = VOVX.load_user_settings(path)

      settings.speaker_id.should eq(3)
      settings.rate.should eq(1.25)
      settings.auto_play?.should be_true
      settings.quit_after_playback?.should be_false
    ensure
      File.delete?(path) if path
      Dir.delete?(File.dirname(path)) if path && Dir.exists?(File.dirname(path))
    end

    it "falls back to empty settings for invalid JSON" do
      path = settings_spec_path
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "invalid")

      settings = VOVX.load_user_settings(path)

      settings.speaker_id.should be_nil
      settings.rate.should be_nil
      settings.auto_play?.should be_false
      settings.quit_after_playback?.should be_true
    ensure
      File.delete?(path) if path
      Dir.delete?(File.dirname(path)) if path && Dir.exists?(File.dirname(path))
    end

    it "clamps rate to the supported slider range" do
      path = settings_spec_path
      Dir.mkdir_p(File.dirname(path))
      File.write(path, %({"speaker_id":1,"rate":9.0}))

      VOVX.load_user_settings(path).rate.should eq(2.0)
    ensure
      File.delete?(path) if path
      Dir.delete?(File.dirname(path)) if path && Dir.exists?(File.dirname(path))
    end

    it "keeps previous playback completion behavior for older settings files" do
      path = settings_spec_path
      Dir.mkdir_p(File.dirname(path))
      File.write(path, %({"speaker_id":1,"rate":1.0}))

      settings = VOVX.load_user_settings(path)

      settings.auto_play?.should be_false
      settings.quit_after_playback?.should be_true
    ensure
      File.delete?(path) if path
      Dir.delete?(File.dirname(path)) if path && Dir.exists?(File.dirname(path))
    end
  end
end

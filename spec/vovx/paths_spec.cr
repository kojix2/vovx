require "../spec_helper"

describe VOVX::Paths do
  describe ".config_dir" do
    it "uses the platform user config directory" do
      with_env("HOME", "/tmp/vovx-home") do
        {% if flag?(:darwin) %}
          VOVX::Paths.config_dir.should eq("/tmp/vovx-home/Library/Application Support/vovx")
        {% else %}
          with_env("XDG_CONFIG_HOME", nil) do
            VOVX::Paths.config_dir.should eq("/tmp/vovx-home/.config/vovx")
          end
        {% end %}
      end
    end
  end

  describe ".settings_path" do
    it "uses VOVX_CONFIG when set" do
      with_env("VOVX_CONFIG", "/tmp/vovx-test-config.json") do
        VOVX::Paths.settings_path.should eq("/tmp/vovx-test-config.json")
      end
    end
  end

  describe ".log_dir" do
    it "uses the platform user log directory" do
      with_env("HOME", "/tmp/vovx-home") do
        {% if flag?(:darwin) %}
          VOVX::Paths.log_dir.should eq("/tmp/vovx-home/Library/Logs/vovx")
        {% else %}
          with_env("XDG_STATE_HOME", nil) do
            VOVX::Paths.log_dir.should eq("/tmp/vovx-home/.local/state/vovx")
          end
        {% end %}
      end
    end
  end

  describe ".log_path" do
    it "uses VOVX_LOG when set" do
      with_env("VOVX_LOG", "/tmp/vovx-test.log") do
        VOVX::Paths.log_path.should eq("/tmp/vovx-test.log")
      end
    end
  end
end

private def with_env(key : String, value : String?, &)
  original = ENV[key]?
  if value
    ENV[key] = value
  else
    ENV.delete(key)
  end

  yield
ensure
  if original
    ENV[key] = original
  else
    ENV.delete(key)
  end
end

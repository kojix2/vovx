require "file_utils"

module VOVX
  SERVICE_WORKFLOW_NAME = "VOVX.workflow"

  def self.install_service_workflow : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューへの追加は macOS でのみ利用できます。"}
    {% end %}

    source = service_workflow_source_path
    unless valid_service_workflow?(source)
      log_event("service.install.source_missing path=#{source}")
      return {false, "同梱されたサービス定義が見つかりませんでした。\n#{source}"}
    end

    destination = service_workflow_destination_path
    services_dir = service_workflow_directory_path
    FileUtils.mkdir_p(services_dir)
    unless Dir.exists?(services_dir)
      log_event("service.install.services_dir_missing path=#{services_dir}")
      return {false, "サービス用ディレクトリを作成できませんでした。\n#{services_dir}"}
    end

    FileUtils.rm_rf(destination) if Dir.exists?(destination) || File.exists?(destination)
    FileUtils.cp_r(source, destination)
    unless valid_service_workflow?(destination)
      log_event("service.install.verify_failed path=#{destination}")
      return {false, "サービス定義をコピーしましたが、内容を確認できませんでした。\n#{destination}"}
    end

    log_event("service.install.done path=#{destination}")
    {true, "サービスメニューに追加しました。\n#{destination}\n\n表示されない場合は、呼び出し元アプリを再起動してください。"}
  rescue ex
    log_event("service.install.failed message=#{ex.message}")
    {false, "サービスメニューへの追加に失敗しました。\n#{ex.message}"}
  end

  def self.uninstall_service_workflow : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューからの削除は macOS でのみ利用できます。"}
    {% end %}

    destination = service_workflow_destination_path
    unless Dir.exists?(destination) || File.exists?(destination)
      return {true, "サービスメニューには追加されていません。"}
    end

    FileUtils.rm_rf(destination)
    log_event("service.uninstall.done path=#{destination}")
    {true, "サービスメニューから削除しました。\n#{destination}\n\n表示が残る場合は、呼び出し元アプリを再起動してください。"}
  rescue ex
    log_event("service.uninstall.failed message=#{ex.message}")
    {false, "サービスメニューからの削除に失敗しました。\n#{ex.message}"}
  end

  def self.open_service_workflow_directory : {Bool, String}
    {% unless flag?(:darwin) %}
      return {false, "サービスメニューのディレクトリは macOS でのみ開けます。"}
    {% end %}

    services_dir = service_workflow_directory_path
    FileUtils.mkdir_p(services_dir)
    status = Process.run(
      "open",
      [services_dir],
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    if status.success?
      log_event("service.open_directory.done path=#{services_dir}")
      {true, "サービスメニューのディレクトリを開きました。\n#{services_dir}"}
    else
      log_event("service.open_directory.failed path=#{services_dir} status=#{status.exit_code}")
      {false, "サービスメニューのディレクトリを開けませんでした。\n#{services_dir}"}
    end
  rescue ex
    log_event("service.open_directory.failed message=#{ex.message}")
    {false, "サービスメニューのディレクトリを開けませんでした。\n#{ex.message}"}
  end

  private def self.service_workflow_source_path : String
    bundled_path = Paths.bundled_resource_path(SERVICE_WORKFLOW_NAME)
    return bundled_path if Dir.exists?(bundled_path)

    Paths.development_resource_path("macos", SERVICE_WORKFLOW_NAME)
  end

  private def self.service_workflow_directory_path : String
    Paths.macos_services_dir
  end

  private def self.service_workflow_destination_path : String
    File.join(service_workflow_directory_path, SERVICE_WORKFLOW_NAME)
  end

  private def self.valid_service_workflow?(path : String) : Bool
    Dir.exists?(path) &&
      File.exists?(File.join(path, "Contents", "Info.plist")) &&
      File.exists?(File.join(path, "Contents", "document.wflow"))
  end
end

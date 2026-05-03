#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="SilentCamera"
BUNDLE_ID="com.silentcamera.app"

echo "=== SilentCamera Xcode プロジェクト生成 ==="

# ruby と gem の確認
if ! command -v ruby &> /dev/null; then
    echo "エラー: ruby が見つかりません"
    exit 1
fi

# xcodeproj gem のインストール確認
if ! gem list xcodeproj -i &> /dev/null; then
    echo "xcodeproj gem をインストールしています..."
    gem install xcodeproj
fi

PROJECT_DIR="$SCRIPT_DIR"
SOURCES_DIR="$PROJECT_DIR/$PROJECT_NAME"

export PROJECT_DIR PROJECT_NAME BUNDLE_ID SOURCES_DIR

ruby << 'RUBY_SCRIPT'
require 'xcodeproj'

project_dir = ENV['PROJECT_DIR'] || Dir.pwd
project_name = ENV['PROJECT_NAME'] || "SilentCamera"
bundle_id = ENV['BUNDLE_ID'] || "com.silentcamera.app"

project_path = File.join(project_dir, "#{project_name}.xcodeproj")

if File.exist?(project_path)
    puts "既存のプロジェクトを削除: #{project_path}"
    FileUtils.rm_rf(project_path)
end

project = Xcodeproj::Project.new(project_path)

# Main target
target = project.new_target(:application, project_name, :ios, "17.0")

# Info.plist
info_plist_path = "#{project_name}/Info.plist"
target.build_configurations.each do |config|
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    config.build_settings["INFOPLIST_FILE"] = info_plist_path
    config.build_settings["MARKETING_VERSION"] = "1.0.0"
    config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
    config.build_settings["SWIFT_VERSION"] = "5.9"
    config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
    config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
    config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
    config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
    config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
    config.build_settings["ENABLE_PREVIEWS"] = "YES"
end

# Swift files
swift_files = Dir.glob(File.join(project_dir, project_name, "**", "*.swift"))
swift_files.each do |file_path|
    relative = file_path.sub("#{project_dir}/", "")
    parts = relative.split("/")
    
    group = project.main_group
    # Create groups for directories (skip the last part which is the filename)
    parts[0..-2].each do |dir|
        next if dir == "."
        existing = group[dir]
        unless existing
            existing = group.new_group(dir, dir)
        end
        group = existing
    end
    
    # File reference should be just the filename
    filename = parts.last
    file_ref = group.new_file(filename)
    target.source_build_phase.add_file_reference(file_ref)
end

# Assets.xcassets
assets_group = project.main_group[project_name]
assets_ref = assets_group.new_file("Assets.xcassets")

# Resources build phase
if assets_ref
    target.resources_build_phase.add_file_reference(assets_ref)
end

# Frameworks
target.frameworks_build_phase.clear
["AVFoundation", "Photos", "UIKit", "SwiftUI"].each do |framework_name|
    framework_ref = project.frameworks_group.new_file("System/Library/Frameworks/#{framework_name}.framework")
    target.frameworks_build_phase.add_file_reference(framework_ref)
end

project.save

puts "プロジェクトが生成されました: #{project_path}"
RUBY_SCRIPT

echo ""
echo "=== 完了 ==="
echo ""
echo "次のステップ:"
echo "1. open $PROJECT_DIR/$PROJECT_NAME.xcodeproj"
echo "2. Xcodeでビルド・実行"
echo ""
echo "注意: 写真ライブラリへのアクセス権限が必要です"

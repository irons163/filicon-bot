#!/usr/bin/env ruby
# Fast fixture tests; no Xcode, app launches, signing identities or user data.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

class ResourceSigningTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(__dir__, 'resource-signing-digest.sh')

  def setup
    @fixture = Dir.mktmpdir('filicon-resource-signing-')
    @resources = File.join(@fixture, 'source resources')
    @output = File.join(@fixture, 'FiliconResources.sha256')
    FileUtils.mkdir_p(File.join(@resources, 'ja.lproj'))
    File.write(File.join(@resources, 'ja.lproj', 'Localizable.strings'), '"Enabled" = "有効";')
  end

  def teardown
    FileUtils.remove_entry(@fixture) # Only the directory created by this test.
  end

  def digest(root = @resources, output = @output)
    stdout, stderr, status = Open3.capture3('/bin/zsh', SCRIPT, root, output)
    assert status.success?, "#{stdout}\n#{stderr}"
    value = File.read(output)
    assert_match(/\A[0-9a-f]{64}\n\z/, value)
    value
  end

  def rejected(root, output)
    _, stderr, status = Open3.capture3('/bin/zsh', SCRIPT, root, output)
    refute status.success?
    assert_includes stderr, 'Resource signing digest:'
  end

  def test_no_op_and_relocated_checkout_have_identical_output
    original = digest
    # No sleeps: give the existing output a fixed mtime to detect any rewrite.
    fixed = Time.at(1_700_000_000)
    File.utime(fixed, fixed, @output)
    assert_equal original, digest
    assert_equal fixed, File.mtime(@output)
    copy = File.join(@fixture, 'relocated')
    FileUtils.cp_r(@resources, copy)
    assert_equal original, digest(copy, File.join(@fixture, 'copy.sha256'))
  end

  def test_resource_bytes_change_digest_without_changing_filename
    original = digest
    File.write(File.join(@resources, 'ja.lproj', 'Localizable.strings'), '"Enabled" = "有効 2";')
    refute_equal original, digest
  end

  def test_add_rename_remove_and_nested_files_are_tracked
    original = digest
    nested = File.join(@resources, 'PetAvatars', 'nested')
    FileUtils.mkdir_p(nested)
    file = File.join(nested, 'avatar.png')
    File.binwrite(file, "\x89PNG\r\n\0fixture")
    added = digest
    refute_equal original, added
    renamed = File.join(nested, 'renamed.png')
    File.rename(file, renamed)
    refute_equal added, digest
    File.unlink(renamed)
    assert_equal original, digest
  end

  def test_dotfiles_unicode_spaces_newlines_and_shell_characters_are_data
    original = digest
    file = File.join(@resources, ".繁體 space\n$(not-a-command)'\".txt")
    File.write(file, 'fixture')
    refute_equal original, digest
    File.unlink(file)
    assert_equal original, digest
  end

  def test_symlinks_are_rejected_without_reading_or_overwriting_targets
    outside = File.join(@fixture, 'outside.txt')
    File.write(outside, 'must remain unchanged')
    resource_link = File.join(@resources, 'link')
    File.symlink(outside, resource_link)
    rejected(@resources, @output)
    refute File.exist?(@output)
    File.unlink(resource_link)
    File.symlink(outside, @output)
    rejected(@resources, @output)
    assert_equal 'must remain unchanged', File.read(outside)
    root_link = File.join(@fixture, 'linked root')
    File.symlink(@resources, root_link)
    rejected(root_link, File.join(@fixture, 'other.sha256'))
  end

  def test_invalid_paths_fail_without_creating_outputs
    rejected(File.join(@fixture, 'missing'), @output)
    rejected(@resources, File.join(@resources, 'recursive.sha256'))
    rejected(@resources, File.join(@fixture, 'missing', 'output.sha256'))
    empty = File.join(@fixture, 'empty')
    Dir.mkdir(empty)
    rejected(empty, @output)
    refute File.exist?(@output)
  end

  def test_checked_in_project_tracks_digest_with_sandbox_enabled
    data, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-',
                                      File.join(ROOT, 'Filicon.xcodeproj', 'project.pbxproj'))
    assert status.success?, error
    objects = JSON.parse(data).fetch('objects')
    app = objects.values.find { |o| o['isa'] == 'PBXNativeTarget' && o['name'] == 'Filicon' }
    phases = app.fetch('buildPhases').map { |id| objects.fetch(id) }
    phase = phases.find { |p| p['name'] == 'Track Resource Signing' }
    refute_nil phase
    assert_equal '1', phase.fetch('alwaysOutOfDate')
    assert_equal '/bin/zsh', phase.fetch('shellPath')
    assert_equal ['$(SRCROOT)/scripts/resource-signing-digest.sh', '$(SRCROOT)/Sources/Filicon/Resources'], phase.fetch('inputPaths')
    assert_equal ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/FiliconResources.sha256'], phase.fetch('outputPaths')
    assert_operator phases.index(phase), :>, phases.index { |p| p['isa'] == 'PBXResourcesBuildPhase' }
    configurations = objects.fetch(app.fetch('buildConfigurationList')).fetch('buildConfigurations')
    configurations.each do |id|
      settings = objects.fetch(id).fetch('buildSettings')
      assert_equal 'YES', settings.fetch('ENABLE_USER_SCRIPT_SANDBOXING')
      assert_equal 'Support/Filicon.entitlements', settings.fetch('CODE_SIGN_ENTITLEMENTS')
    end
  end
end

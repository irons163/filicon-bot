#!/usr/bin/env ruby
# Only isolated temporary fixtures. Never downloads or executes package code.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'

class KaTeXResourceTest < Minitest::Test
  SOURCE = File.expand_path('../Sources/FiliconRichContent/Resources/KaTeX', __dir__)
  VERIFY = File.join(__dir__, 'verify-katex.rb')
  IMPORT = File.join(__dir__, 'import-katex.rb')

  def setup
    @fixture = Dir.mktmpdir('filicon-katex-verify-')
    @root = File.join(@fixture, 'KaTeX')
    FileUtils.cp_r(SOURCE, @root)
  end

  def teardown
    FileUtils.remove_entry(@fixture) # Exactly the test-created directory.
  end

  def verify(root = @root)
    Open3.capture3(RbConfig.ruby, VERIFY, root)
  end

  def rejected(root = @root)
    _, _, status = verify(root)
    refute status.success?
  end

  def test_complete_resources_keep_the_pinned_manifest_and_license
    stdout, stderr, status = verify
    assert status.success?, stderr
    assert_includes stdout, '20 fonts and MIT notice'
    assert_equal 24, Dir.glob(File.join(@root, '**', '*')).count { |p| File.file?(p) }
    assert_equal 'd4b959a788c2804d10b996b32be1eaf83f997eaf917b4a7767e0aaf26d6a7ee9',
                 Digest::SHA256.file(File.join(@root, 'manifest.json')).hexdigest
  end

  def test_every_resource_is_required_and_its_bytes_are_pinned
    Dir.glob(File.join(@root, '**', '*')).select { |p| File.file?(p) }.each do |path|
      bytes = File.binread(path)
      File.binwrite(path, bytes + 'changed')
      rejected
      File.unlink(path)
      rejected
      File.binwrite(path, bytes)
    end
    assert verify.last.success?
  end

  def test_resource_manifest_and_font_symlinks_cannot_substitute_matching_bytes
    %w[manifest.json LICENSE katex.min.js katex.min.css fonts/KaTeX_Main-Regular.woff2].each do |relative|
      path = File.join(@root, relative)
      external = File.join(@fixture, 'external')
      bytes = File.binread(path)
      File.binwrite(external, bytes)
      File.unlink(path)
      File.symlink(external, path)
      rejected
      assert_equal bytes, File.binread(external)
      File.unlink(path)
      File.binwrite(path, bytes)
    end
    File.rename(File.join(@root, 'fonts'), File.join(@fixture, 'fonts'))
    File.symlink(File.join(@fixture, 'fonts'), File.join(@root, 'fonts'))
    rejected
    alias_path = File.join(@fixture, 'alias')
    File.symlink(@root, alias_path)
    rejected(alias_path)
    rejected(File.join(@fixture, 'missing'))
  end

  def test_import_rejects_an_unrecognized_archive_before_creating_resources
    importer, root = isolated_importer
    archive = File.join(@fixture, 'invalid.tgz')
    File.binwrite(archive, 'not the pinned package')
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive)
    refute status.success?
    assert_includes stderr, 'integrity mismatch'
    refute File.exist?(root)
  end

  def test_pinned_archive_import_is_byte_preserving_and_reproducible
    archive = ENV['FILICON_KATEX_IMPORT_ARCHIVE']
    skip 'Provide the pinned local archive to verify reproducible import.' unless archive
    importer, root = isolated_importer
    2.times do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive)
      assert status.success?, "#{stdout}\n#{stderr}"
      assert verify(root).last.success?
      Dir.glob(File.join(SOURCE, '**', '*')).select { |p| File.file?(p) }.each do |source|
        assert_equal File.binread(source), File.binread(File.join(root, source.delete_prefix(SOURCE + '/')))
      end
    end
  end

  def test_import_checks_all_destination_symlinks_before_writing_any_bytes
    archive = ENV['FILICON_KATEX_IMPORT_ARCHIVE']
    skip 'Provide the pinned local archive to verify import path guards.' unless archive
    importer, root = isolated_importer
    FileUtils.cp_r(SOURCE, root)
    license = File.join(root, 'LICENSE')
    File.binwrite(license, 'must not overwrite')
    fonts = File.join(root, 'fonts')
    File.rename(fonts, File.join(@fixture, 'external-fonts'))
    File.symlink(File.join(@fixture, 'external-fonts'), fonts)
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive)
    refute status.success?
    assert_includes stderr, 'refusing symlink'
    assert_equal 'must not overwrite', File.binread(license)
  end

  private

  def isolated_importer
    scripts = File.join(@fixture, 'scripts')
    FileUtils.mkdir_p(scripts)
    importer = File.join(scripts, 'import-katex.rb')
    FileUtils.cp(IMPORT, importer)
    root = File.join(@fixture, 'Sources/FiliconRichContent/Resources/KaTeX')
    FileUtils.mkdir_p(File.dirname(root))
    [importer, root]
  end
end

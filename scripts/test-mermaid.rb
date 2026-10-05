#!/usr/bin/env ruby
# Offline fixtures only; never evaluates JavaScript or downloads dependencies.
require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class MermaidResourceTest < Minitest::Test
  SOURCE = File.expand_path('../Sources/FiliconRichContent/Resources/Mermaid', __dir__)
  VERIFY = File.join(__dir__, 'verify-mermaid.rb')
  IMPORT = File.join(__dir__, 'import-mermaid.rb')
  LOCK = File.join(__dir__, 'mermaid-vendor-lock.json')

  def setup
    @fixture = Dir.mktmpdir('filicon-mermaid-verify-')
    @root = File.join(@fixture, 'Mermaid')
    FileUtils.cp_r(SOURCE, @root)
  end

  def teardown
    FileUtils.remove_entry(@fixture)
  end

  def verify(root = @root)
    Open3.capture3(RbConfig.ruby, VERIFY, root)
  end

  def test_complete_distribution_preserves_engine_and_all_notice_bytes
    stdout, stderr, status = verify
    assert status.success?, stderr
    assert_includes stdout, '72 pinned component notices'
    assert_equal 75, Dir.glob(File.join(@root, '**', '*')).count { |path| File.file?(path) }
    assert_equal '9a4d4a9751de0820b953ef699dcf0382c80612ce5c7c6146fea65761749c462b', Digest::SHA256.file(File.join(@root, 'manifest.json')).hexdigest
    lock = JSON.parse(File.read(LOCK))
    assert_equal 72, lock.fetch('components').length
    assert lock.fetch('components').all? { |component| component.fetch('notices').length == 1 }
    assert_equal 32, lock.fetch('embeddedParserMatches')
  end

  def test_every_file_and_notice_is_required_and_pinned
    Dir.glob(File.join(@root, '**', '*')).select { |path| File.file?(path) }.each do |path|
      bytes = File.binread(path)
      File.binwrite(path, bytes + 'changed')
      refute verify.last.success?, path
      File.unlink(path)
      refute verify.last.success?, path
      File.binwrite(path, bytes)
    end
    assert verify.last.success?
  end

  def test_files_and_each_notice_directory_level_reject_symlink_substitution
    %w[manifest.json mermaid.min.js LICENSE notices/dompurify-3.4.0/LICENSE].each do |relative|
      path = File.join(@root, relative)
      external = File.join(@fixture, 'external')
      bytes = File.binread(path)
      File.binwrite(external, bytes)
      File.unlink(path)
      File.symlink(external, path)
      refute verify.last.success?
      assert_equal bytes, File.binread(external)
      File.unlink(path)
      File.binwrite(path, bytes)
    end
    %w[notices/dompurify-3.4.0 notices].each_with_index do |relative, index|
      path = File.join(@root, relative)
      external = File.join(@fixture, "directory-#{index}")
      File.rename(path, external)
      File.symlink(external, path)
      refute verify.last.success?
      File.unlink(path)
      File.rename(external, path)
    end
    alias_path = File.join(@fixture, 'alias')
    File.symlink(@root, alias_path)
    refute verify(alias_path).last.success?
    refute verify(File.join(@fixture, 'missing')).last.success?
  end

  def test_unlisted_files_cannot_be_smuggled_into_the_packaged_distribution
    File.write(File.join(@root, 'extra.js'), 'not allowed')
    refute verify.last.success?
  end

  def test_git_export_preserves_every_resource_with_line_ending_conversion_enabled
    repository = File.join(@fixture, 'git-fixture')
    resource = File.join(repository, 'Sources/FiliconRichContent/Resources/Mermaid')
    FileUtils.mkdir_p(File.dirname(resource))
    FileUtils.cp_r(SOURCE, resource)
    FileUtils.cp(File.expand_path('../.gitattributes', __dir__), repository)
    env = { 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL,
            'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil }
    git = lambda do |*arguments|
      stdout, stderr, status = Open3.capture3(env, 'git', '-C', repository,
        '-c', 'core.autocrlf=true', '-c', 'core.hooksPath=' + File::NULL, *arguments)
      assert status.success?, "#{stdout}\n#{stderr}"
    end
    git.call('init', '-q')
    git.call('add', '--', '.gitattributes', 'Sources/FiliconRichContent/Resources/Mermaid')
    exported = File.join(@fixture, 'exported') + '/'
    git.call('checkout-index', '--all', '--prefix=' + exported)
    Dir.glob(File.join(SOURCE, '**', '*')).select { |path| File.file?(path) }.each do |path|
      target = File.join(exported, 'Sources/FiliconRichContent/Resources/Mermaid', path.delete_prefix(SOURCE + '/'))
      assert_equal File.binread(path), File.binread(target)
    end
  end

  def test_bad_archive_and_changed_lock_fail_before_any_vendor_write
    importer, root, lock = isolated_importer
    archive = File.join(@fixture, 'bad.tgz')
    File.write(archive, 'not the pinned distribution')
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive, @fixture)
    refute status.success?
    assert_includes stderr, 'archive integrity mismatch'
    refute File.exist?(root)
    File.write(lock, File.read(lock) + 'changed')
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive, @fixture)
    refute status.success?
    assert_includes stderr, 'unrecognized Mermaid vendor lock'
    refute File.exist?(root)
  end

  def test_pinned_local_archives_reimport_every_byte_reproducibly
    archive, cache = local_inputs
    importer, root, = isolated_importer
    2.times do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive, cache)
      assert status.success?, "#{stdout}\n#{stderr}"
      assert verify(root).last.success?
      Dir.glob(File.join(SOURCE, '**', '*')).select { |path| File.file?(path) }.each do |path|
        assert_equal File.binread(path), File.binread(File.join(root, path.delete_prefix(SOURCE + '/')))
      end
    end
  end

  def test_late_notice_symlink_rejects_import_before_overwriting_earlier_engine
    archive, cache = local_inputs
    importer, root, = isolated_importer
    FileUtils.cp_r(SOURCE, root)
    engine = File.join(root, 'mermaid.min.js')
    File.write(engine, 'must not overwrite')
    notices = File.join(root, 'notices')
    File.rename(notices, File.join(@fixture, 'external-notices'))
    File.symlink(File.join(@fixture, 'external-notices'), notices)
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive, cache)
    refute status.success?
    assert_includes stderr, 'refusing symlinked import path'
    assert_equal 'must not overwrite', File.read(engine)
  end

  def test_missing_last_notice_archive_does_not_create_a_partial_import
    archive, cache = local_inputs
    importer, root, = isolated_importer
    isolated_cache = File.join(@fixture, 'archive-cache')
    Dir.mkdir(isolated_cache)
    components = JSON.parse(File.read(LOCK)).fetch('components')
    components[0...-1].each do |component|
      FileUtils.cp(File.join(cache, component.fetch('cacheFile')), isolated_cache)
    end
    _, stderr, status = Open3.capture3(RbConfig.ruby, importer, archive, isolated_cache)
    refute status.success?
    assert_includes stderr, 'archive must be regular'
    refute File.exist?(root)
  end

  private

  def local_inputs
    archive, cache = ENV.values_at('FILICON_MERMAID_IMPORT_ARCHIVE', 'FILICON_MERMAID_NOTICE_ARCHIVES')
    skip 'Provide the pinned local archives for import-specific verification.' unless archive && cache
    [archive, cache]
  end

  def isolated_importer
    scripts = File.join(@fixture, 'scripts')
    FileUtils.mkdir_p(scripts)
    importer = File.join(scripts, 'import-mermaid.rb')
    lock = File.join(scripts, 'mermaid-vendor-lock.json')
    FileUtils.cp(IMPORT, importer)
    FileUtils.cp(LOCK, lock)
    root = File.join(@fixture, 'Sources/FiliconRichContent/Resources/Mermaid')
    FileUtils.mkdir_p(File.dirname(root))
    [importer, root, lock]
  end
end

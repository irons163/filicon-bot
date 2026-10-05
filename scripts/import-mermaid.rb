#!/usr/bin/env ruby
# Byte-preserving, offline import. Does not install or execute package code.
require 'digest'
require 'fileutils'
require 'json'
require 'rubygems/package'
require 'zlib'

abort 'usage: ruby scripts/import-mermaid.rb /explicit/path/mermaid-11.16.0.tgz /explicit/path/notice-archives' unless ARGV.length == 2
lock_path = File.join(__dir__, 'mermaid-vendor-lock.json')
abort 'symlinked vendor lock' if File.symlink?(lock_path)
lock_bytes = File.binread(lock_path)
abort 'unrecognized Mermaid vendor lock' unless Digest::SHA256.hexdigest(lock_bytes) == '44645fae85c2e2bbf32dad42eb9a5daf9a18b345ee0ce009aa38e140499a1204'
lock = JSON.parse(lock_bytes)
cache = File.expand_path(ARGV.fetch(1))
abort 'notice archive directory must be regular' unless File.directory?(cache) && !File.symlink?(cache)

def verified_archive(path, integrity)
  abort "archive must be regular: #{path}" unless File.file?(path) && !File.symlink?(path)
  bytes = File.binread(path)
  abort "archive integrity mismatch: #{path}" unless "sha512-#{[Digest::SHA512.digest(bytes)].pack('m0')}" == integrity
  bytes
end

def entries(bytes, expected)
  files = {}
  Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gzip|
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        path = entry.full_name
        next unless expected.key?(path)
        abort "unsafe or duplicate archive entry: #{path}" unless entry.file? && !files.key?(path)
        data = entry.read
        metadata = expected.fetch(path)
        abort "entry integrity mismatch: #{path}" unless data.bytesize == metadata.fetch('bytes') && Digest::SHA256.hexdigest(data) == metadata.fetch('sha256')
        files[path] = data
      end
    end
  end
  abort 'missing required archive entries' unless files.keys.sort == expected.keys.sort
  files
end

files = {}
mermaid_archive = verified_archive(File.expand_path(ARGV.fetch(0)), lock.fetch('integrity'))
entries(mermaid_archive, lock.fetch('files')).each do |path, bytes|
  files[path.sub(%r{\Apackage/(?:dist/)?}, '')] = bytes
end
lock.fetch('components').each do |component|
  cached = component.fetch('cacheFile')
  abort 'unsafe archive cache name' unless cached.match?(/\A[a-z0-9+_.-]+\.tgz\z/)
  bytes = verified_archive(File.join(cache, cached), component.fetch('integrity'))
  abort 'wrong notice archive bytes' unless bytes.bytesize == component.fetch('archiveBytes') && Digest::SHA256.hexdigest(bytes) == component.fetch('archiveSHA256')
  entries(bytes, component.fetch('notices')).each do |path, notice|
    basename = File.basename(path)
    abort 'unsafe notice filename' unless basename.match?(/\A(?:licen[sc]e|copying|notice)(?:\.(?:txt|md|markdown|rst))?\z/i)
    relative = "notices/#{cached.delete_suffix('.tgz')}/#{basename}"
    abort 'duplicate notice destination' if files.key?(relative)
    files[relative] = notice
  end
end
abort 'incomplete Mermaid resource import' unless files.length == 74
manifest = lock.merge('files' => files.sort.to_h.transform_values { |bytes| { 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes) } })
files['manifest.json'] = JSON.pretty_generate(manifest) + "\n"
root = File.expand_path('../Sources/FiliconRichContent/Resources/Mermaid', __dir__)
destinations = files.keys.map { |path| File.join(root, path) }

# Verify every ancestor and destination before any write. A later notice
# symlink or invalid archive must not leave a partially replaced distribution.
destinations.each do |destination|
  path = destination
  loop do
    abort "refusing symlinked import path: #{path}" if File.symlink?(path)
    if File.exist?(path)
      valid = path == destination ? File.file?(path) : File.directory?(path)
      abort "invalid import destination: #{path}" unless valid
    end
    parent = File.dirname(path)
    break if parent == path
    path = parent
  end
end
if File.directory?(root)
  require 'find'
  Find.find(root) do |path|
    abort "refusing symlinked import path: #{path}" if File.symlink?(path)
    abort "unexpected existing vendor file: #{path}" if File.file?(path) && !destinations.include?(path)
  end
end
files.each do |relative, bytes|
  destination = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(destination))
  File.binwrite(destination, bytes)
end
puts 'Imported public Mermaid 11.16.0: unchanged IIFE engine, MIT notice and 72 pinned component notices.'
puts "Manifest SHA256=#{Digest::SHA256.file(File.join(root, 'manifest.json')).hexdigest}"

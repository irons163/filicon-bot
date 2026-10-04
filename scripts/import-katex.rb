#!/usr/bin/env ruby
# Mechanical, byte-preserving vendor import. Never executes package scripts.
require 'digest'
require 'json'
require 'rubygems/package'
require 'zlib'
require 'fileutils'

version = '0.16.45'
integrity = 'pQpZbdBu7wCTmQUh7ufPmLr0pFoObnGUoL/yhtwJDgmmQpbkg/0HSVti25Fu4rmd1oCR6NGWe9vqTWuWv3GcNA=='
abort 'usage: ruby scripts/import-katex.rb /explicit/path/katex-0.16.45.tgz' unless ARGV.length == 1
archive = File.binread(ARGV.fetch(0))
abort 'KaTeX archive integrity mismatch' unless [Digest::SHA512.digest(archive)].pack('m0') == integrity
files = {}
Zlib::GzipReader.wrap(StringIO.new(archive)) do |gzip|
  Gem::Package::TarReader.new(gzip) do |tar|
    tar.each do |entry|
      path = entry.full_name
      selected = %w[package/LICENSE package/dist/katex.min.js package/dist/katex.min.css].include?(path) ||
                 path.match?(%r{\Apackage/dist/fonts/KaTeX_[A-Za-z0-9_-]+\.woff2\z})
      next unless selected
      abort "unsafe or duplicate archive entry: #{path}" unless entry.file? && !files.key?(path)
      files[path] = entry.read
    end
  end
end
abort 'incomplete KaTeX distribution' unless files.length == 23 && files.keys.count { |p| p.end_with?('.woff2') } == 20
root = File.expand_path('../Sources/FiliconRichContent/Resources/KaTeX', __dir__)
ancestor = root
loop do
  abort "refusing symlinked resource ancestor: #{ancestor}" if File.symlink?(ancestor)
  parent = File.dirname(ancestor)
  break if parent == ancestor
  ancestor = parent
end
manifest = {
  'package' => 'katex', 'version' => version,
  'source' => "https://registry.npmjs.org/katex/-/katex-#{version}.tgz",
  'integrity' => "sha512-#{integrity}", 'license' => 'MIT',
  'referenceCommit' => 'a9f633e09d49a85829b8236331b9e21f7e612634',
  'provenance' => 'Public package pinned by reference package-lock.json; not copied from opaque recovered app assets.',
  'files' => {}
}
destinations = files.keys.map { |original| File.join(root, original.sub(%r{\Apackage/(?:dist/)?}, '')) }
manifest_path = File.join(root, 'manifest.json')
# Check every destination before writing any bytes, including the fonts
# directory and manifest. A late symlink must not leave a partial import.
(destinations + [manifest_path]).each do |destination|
  abort "refusing symlink: #{destination}" if File.symlink?(destination) || File.symlink?(File.dirname(destination))
end
files.sort.each do |original, bytes|
  relative = original.sub(%r{\Apackage/(?:dist/)?}, '')
  destination = File.join(root, relative)
  abort "refusing symlink: #{destination}" if File.symlink?(destination)
  FileUtils.mkdir_p(File.dirname(destination))
  File.binwrite(destination, bytes)
  manifest['files'][relative] = {'sha256' => Digest::SHA256.hexdigest(bytes), 'bytes' => bytes.bytesize}
end
File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
puts "Imported #{files.length} verified KaTeX #{version} resources (including MIT license and 20 WOFF2 fonts)."

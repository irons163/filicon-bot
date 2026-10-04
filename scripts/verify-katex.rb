#!/usr/bin/env ruby
require 'digest'
require 'json'

abort 'usage: ruby scripts/verify-katex.rb /explicit/path/KaTeX' unless ARGV.length == 1
root = File.expand_path(ARGV.fetch(0))
abort 'KaTeX resource root must be a regular directory' unless File.directory?(root) && !File.symlink?(root)
manifest_path = File.join(root, 'manifest.json')
abort 'symlinked manifest' if File.symlink?(manifest_path)
manifest_bytes = File.binread(manifest_path)
abort 'unrecognized KaTeX manifest' unless Digest::SHA256.hexdigest(manifest_bytes) ==
  'd4b959a788c2804d10b996b32be1eaf83f997eaf917b4a7767e0aaf26d6a7ee9'
manifest = JSON.parse(manifest_bytes)
abort 'wrong KaTeX version or provenance' unless manifest['version'] == '0.16.45' &&
  manifest['integrity'] == 'sha512-pQpZbdBu7wCTmQUh7ufPmLr0pFoObnGUoL/yhtwJDgmmQpbkg/0HSVti25Fu4rmd1oCR6NGWe9vqTWuWv3GcNA==' &&
  manifest['license'] == 'MIT'
files = manifest.fetch('files')
abort 'incomplete math resources' unless files.length == 23 &&
  %w[LICENSE katex.min.js katex.min.css].all? { |path| files.key?(path) } &&
  files.keys.count { |path| path.match?(%r{\Afonts/KaTeX_[A-Za-z0-9_-]+\.woff2\z}) } == 20
files.each do |path, expected|
  abort 'unsafe resource path' unless %w[LICENSE katex.min.js katex.min.css].include?(path) ||
    path.match?(%r{\Afonts/KaTeX_[A-Za-z0-9_-]+\.woff2\z})
  candidate = File.join(root, path)
  abort "symlinked resource: #{path}" if File.symlink?(candidate) || File.symlink?(File.dirname(candidate))
  bytes = File.binread(candidate)
  abort "resource integrity mismatch: #{path}" unless bytes.bytesize == expected.fetch('bytes') &&
    Digest::SHA256.hexdigest(bytes) == expected.fetch('sha256')
end
abort 'missing license notice' unless File.read(File.join(root, 'LICENSE')).include?('Copyright (c) 2013-2020 Khan Academy')
puts 'Verified KaTeX 0.16.45: engine, stylesheet, 20 fonts and MIT notice.'

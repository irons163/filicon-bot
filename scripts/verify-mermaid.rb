#!/usr/bin/env ruby
require 'digest'
require 'find'
require 'json'

abort 'usage: ruby scripts/verify-mermaid.rb /explicit/path/Mermaid' unless ARGV.length == 1
root = File.expand_path(ARGV.fetch(0))
abort 'Mermaid resource root must be a regular directory' unless File.directory?(root) && !File.symlink?(root)
manifest_path = File.join(root, 'manifest.json')
abort 'manifest must be regular' unless File.file?(manifest_path) && !File.symlink?(manifest_path)
manifest_bytes = File.binread(manifest_path)
abort 'unrecognized Mermaid manifest' unless Digest::SHA256.hexdigest(manifest_bytes) == '9a4d4a9751de0820b953ef699dcf0382c80612ce5c7c6146fea65761749c462b'
manifest = JSON.parse(manifest_bytes)
abort 'wrong Mermaid version or provenance' unless manifest['package'] == 'mermaid' && manifest['version'] == '11.16.0' &&
  manifest['integrity'] == 'sha512-Zvm3kbstgdpvIJPPItlL7fppIZ3kibvc1oZIGxdvk9t6UFz6flv+Jw7FtRGKwfcI8OckmH04LqG6LlS6X4B1pA==' &&
  manifest.fetch('components').length == 72 && manifest['embeddedParserMatches'] == 32
files = manifest.fetch('files')
abort 'incomplete Mermaid resources' unless files.length == 74 && files.key?('LICENSE') && files.key?('mermaid.min.js')
files.each do |relative, metadata|
  safe = %w[LICENSE mermaid.min.js].include?(relative) || relative.match?(%r{\Anotices/[a-z0-9+_.-]+/(?:licen[sc]e|copying|notice)(?:\.(?:txt|md|markdown|rst))?\z}i)
  abort 'unsafe resource path' unless safe && !relative.include?('..')
  path = File.join(root, relative)
  cursor = path
  loop do
    abort "symlinked resource path: #{relative}" if File.symlink?(cursor)
    break if cursor == root
    cursor = File.dirname(cursor)
  end
  abort "resource must be regular: #{relative}" unless File.file?(path)
  bytes = File.binread(path)
  abort "resource integrity mismatch: #{relative}" unless bytes.bytesize == metadata.fetch('bytes') && Digest::SHA256.hexdigest(bytes) == metadata.fetch('sha256')
end
allowed = files.keys.map { |relative| File.join(root, relative) } + [manifest_path]
Find.find(root) do |path|
  abort "unexpected resource symlink: #{path}" if File.symlink?(path)
  abort "unexpected resource file: #{path}" if File.file?(path) && !allowed.include?(path)
end
puts 'Verified public Mermaid 11.16.0: engine, MIT notice and 72 pinned component notices.'

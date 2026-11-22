# frozen_string_literal: true
# Evaluate the release Cask with Homebrew's own DSL and inspect the resolved
# installation metadata before it can enter the public tap.
require "cask/cask_loader"

path, version, digest = ARGV
abort "usage: validate_cask.rb CASK VERSION SHA256" unless path && version && digest

source = File.read(path)
loader = Cask::CaskLoader
cask = if loader.respond_to?(:from_content)
  loader.from_content(source)
else
  # GitHub's macOS runner can have an older Homebrew without from_content.
  # Its content loader still evaluates the same Cask DSL in memory.
  legacy = loader::FromContentLoader.new(source)
  accepts_config = legacy.method(:load).parameters.any? { |kind, name| [:key, :keyreq].include?(kind) && name == :config }
  accepts_config ? legacy.load(config: nil) : legacy.load
end
expected_url = "https://github.com/maxmeis/hypermug/releases/download/v#{version}/HyperMug-#{version}.zip"
abort "unexpected Cask token" unless cask.token == "hypermug"
abort "unexpected Cask version" unless cask.version.to_s == version
abort "unexpected Cask digest" unless cask.sha256.to_s == digest
abort "unexpected Cask URL" unless cask.url.to_s == expected_url
abort "Cask must declare automatic updates" unless cask.auto_updates
abort "Cask must install HyperMug.app" unless cask.artifacts.any? { |artifact|
  artifact.is_a?(Cask::Artifact::App) && artifact.source.basename.to_s == "HyperMug.app"
}
abort "Cask must target Apple Silicon" unless cask.depends_on[:arch] == [{ type: :arm, bits: 64 }]
abort "Cask must require macOS Sonoma" unless cask.depends_on[:macos]&.minimum_version&.to_s == "14"

# typed: false
# frozen_string_literal: true

# Applies `brew style <tap>` rules to this checkout, installed or not: `brew ruby test/style.rb -- [options] [files]`.
# `brew style` isolates the index and applies the `Taps/...` rule scopes only under Library/Taps, so this runs
# RuboCop from this directory and moves those scopes here.

require "tmpdir"
require "yaml"

system(HOMEBREW_BREW_FILE.to_s, "install-bundler-gems", "--add-groups=style") || exit(1)

root = File.expand_path("..", __dir__)
homebrew_config = HOMEBREW_LIBRARY/".rubocop.yml"
homebrew_rules = YAML.safe_load_file(homebrew_config, aliases: true, permitted_classes: [Regexp, Symbol])

excludes = homebrew_rules.filter_map do |cop, settings|
  next unless settings.is_a?(Hash)

  tap_paths = Array(settings["Exclude"]).select { |path| path.start_with?("Taps/*/*/", "Taps/**/") }
  next if tap_paths.empty?

  moved_paths = tap_paths.map { |path| path.sub("Taps/*/*/", "#{root}/").sub("Taps/**/", "#{root}/**/") }
  [cop, { "inherit_mode" => { "merge" => ["Exclude"] }, "Exclude" => moved_paths }]
end.to_h

# `--only Style/Foo` has a value that is not a file, so a name counts as a file only when it exists.
files, options = ARGV.partition { |argument| File.file?(argument) }
files = if files.empty?
  Dir.glob("{cmd,lib,test}/**/*.rb", base: root)
else
  files.map { |file| File.expand_path(file) }
end

Dir.mktmpdir do |directory|
  config = File.join(directory, "tap_style.yml")
  File.write(config, YAML.dump({ "inherit_from" => homebrew_config.to_s }.merge(excludes)))

  success = system(*HOMEBREW_RUBY_EXEC_ARGS, "--", (HOMEBREW_LIBRARY_PATH/"utils/rubocop.rb").to_s,
                   "--force-exclusion", "--cache", "false", "--format", "clang",
                   "--config", config, *options, *files, chdir: root)
  exit(success ? 0 : 1)
end

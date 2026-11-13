# typed: false
# frozen_string_literal: true

# Integration tests for `brew substitute`. They install and uninstall real formulae, so they run only in a
# disposable Homebrew prefix: the sandbox in CLAUDE.md, or a CI runner. Run them through `brew ruby`, so that they
# use Homebrew's Ruby:
#
#   HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1 HOMEBREW_CACHE=<scratch>/cache HOMEBREW_LOGS=<scratch>/logs \
#     <sandbox>/bin/brew ruby test/integration.rb
#
# HOMEBREW_SUBSTITUTE_TEST_ONLY=<text> runs only the scenarios whose name contains the text.

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

if ENV["HOMEBREW_SUBSTITUTE_TEST_SANDBOX"] != "1"
  abort "These tests uninstall formulae. Set HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1 to confirm that this prefix " \
        "is disposable."
end
if ENV["HOMEBREW_CACHE"] == ENV["HOMEBREW_DEFAULT_CACHE"] || ENV["HOMEBREW_LOGS"] == ENV["HOMEBREW_DEFAULT_LOGS"]
  abort "Set HOMEBREW_CACHE and HOMEBREW_LOGS to a scratch directory. A sandbox shares the default ones with the " \
        "real install."
end

REPO = File.expand_path("..", __dir__).freeze
BREW = ENV.fetch("HOMEBREW_BREW_FILE").freeze
PREFIX = ENV.fetch("HOMEBREW_PREFIX").freeze
TAPS = File.join(ENV.fetch("HOMEBREW_REPOSITORY"), "Library", "Taps").freeze
TEST_USER = "substitute-test"
PROBE_TAP = "#{TEST_USER}/probe".freeze
PROBE_FORMULAE = File.join(TAPS, TEST_USER, "homebrew-probe", "Formula").freeze
TOOL_TAP_LINK = File.join(TAPS, TEST_USER, "homebrew-substitute").freeze
ONLY = ENV.fetch("HOMEBREW_SUBSTITUTE_TEST_ONLY", nil).freeze
MACOS = RUBY_PLATFORM.include?("darwin").freeze
DOT_ENTRIES = %w[. ..].freeze

SCRIPT = <<~SH
  #!/bin/sh
  echo fixture
SH

LIBRARY_SOURCE = <<~C
  int sublib_value(void) { return 42; }
C

LIBRARY_USER_SOURCE = <<~C
  int sublib_value(void);
  int main(void) { return sublib_value() == 42 ? 0 : 1; }
C

LIBRARY_INSTALL = <<~RUBY
  if OS.mac?
    system ENV.cc, "-dynamiclib", "-install_name", "\#{opt_lib}/libsublib.dylib", "-o", "libsublib.dylib", "libsublib.c"
    lib.install "libsublib.dylib"
  else
    system ENV.cc, "-shared", "-fPIC", "-o", "libsublib.so", "libsublib.c"
    lib.install "libsublib.so"
  end
RUBY

FORMULAE = {
  "subtest"       => { tarball: :v1, install: 'bin.install "subtest"' },
  "subtest-full"  => { tarball: :v1, keg_only: true, install: 'bin.install "subtest" => "subtest-full"' },
  "subtest-alt"   => { tarball: :v1, keg_only: true, install: 'bin.install "subtest" => "subtest-alt"' },
  "subtest-v2"    => { tarball: :v2, keg_only: true, install: 'bin.install "subtest" => "subtest-v2"' },
  "subtest-user"  => { tarball: :v1, depends_on: "subtest", install: 'bin.install "subtest" => "subtest-user"' },
  "subtest-user2" => { tarball: :v1, depends_on: "subtest", install: 'bin.install "subtest" => "subtest-user2"' },
  "sublib"        => { tarball: :lib, install: LIBRARY_INSTALL },
  # Ships no library, so a dependent of `sublib` cannot load it through the stub.
  "sublib-full"   => { tarball: :v1, keg_only: true, install: 'bin.install "subtest" => "sublib-full"' },
  "sublib-good"   => { tarball: :lib, keg_only: true, install: LIBRARY_INSTALL },
  "sublib-user"   => {
    tarball:    :lib,
    depends_on: "sublib",
    install:    <<~RUBY,
      system ENV.cc, "main.c", "-L\#{Formula["sublib"].opt_lib}", "-lsublib", "-o", "sublib-user"
      bin.install "sublib-user"
    RUBY
  },
}.freeze

Result = Struct.new(:output, :code) do
  def success? = code.zero?
end

@failures = []
@scenario = nil
@revisions = Hash.new(0)
@archives = {}

def brew(*args)
  output, status = Open3.capture2e(BREW, *args)
  # A process that a signal kills has no exit status. Use the shell convention of 128 plus the signal number.
  Result.new(output, status.exitstatus || (128 + status.termsig))
end

def brew!(*args)
  result = brew(*args)
  raise "brew #{args.join(" ")} exited #{result.code}:\n#{result.output}" unless result.success?

  result
end

def check(label, condition, detail = nil)
  puts "  #{condition ? "ok  " : "FAIL"} #{label}"
  return if condition

  puts detail.to_s.gsub(/^/, "         ") unless detail.to_s.empty?
  @failures << "#{@scenario}: #{label}"
end

def check_exit(label, result, code)
  check "#{label} exits #{code}", result.code == code, result.output
end

def check_output(label, result, text)
  check "#{label} prints #{text.inspect}", result.output.include?(text), result.output
end

def make_archive(name, version, files)
  source = File.join(@work, "src")
  directory = File.join(source, "#{name}-#{version}")
  FileUtils.mkdir_p(directory)
  files.each do |file, (mode, content)|
    path = File.join(directory, file)
    File.write(path, content)
    File.chmod(mode, path)
  end
  archive = "#{directory}.tar.gz"
  system("tar", "-czf", archive, "-C", source, "#{name}-#{version}", exception: true)
  archive
end

def make_archives
  @archives = {
    v1:  make_archive("subtest", "1.0", "subtest" => [0755, SCRIPT]),
    v2:  make_archive("subtest", "2.0", "subtest" => [0755, SCRIPT]),
    lib: make_archive("sublib", "1.0", "libsublib.c" => [0644, LIBRARY_SOURCE],
                                       "main.c"      => [0644, LIBRARY_USER_SOURCE]),
  }
end

def formula_source(name, spec)
  archive = @archives.fetch(spec.fetch(:tarball))
  lines = [
    "class #{name.split("-").map(&:capitalize).join} < Formula",
    '  desc "Test fixture"',
    '  homepage "https://example.invalid"',
    %Q(  url "file://#{archive}"),
    %Q(  sha256 "#{Digest::SHA256.file(archive).hexdigest}"),
  ]
  lines << "  revision #{@revisions[name]}" if @revisions[name].positive?
  lines << "  keg_only :versioned_formula" if spec[:keg_only]
  lines << %Q(  depends_on "#{spec[:depends_on]}") if spec[:depends_on]
  lines << "  def install"
  lines.concat(spec.fetch(:install).lines.map { |line| "    #{line}".rstrip })
  lines.push("  end", "end", "")
  lines.join("\n")
end

def write_formulae(directory)
  FileUtils.mkdir_p(directory)
  FORMULAE.each { |name, spec| File.write(File.join(directory, "#{name}.rb"), formula_source(name, spec)) }
end

def bump_revision(name)
  @revisions[name] += 1
  File.write(File.join(PROBE_FORMULAE, "#{name}.rb"), formula_source(name, FORMULAE.fetch(name)))
end

def stub_dir(name, version) = File.join(PREFIX, "Cellar", name, version)
def pinned?(name) = File.symlink?(File.join(PREFIX, "var", "homebrew", "pinned", name))
def linked?(name) = File.symlink?(File.join(PREFIX, "var", "homebrew", "linked", name))
def stub?(name, version) = File.symlink?(File.join(stub_dir(name, version), ".substituted-by"))

def real_keg?(name, version) = File.directory?(stub_dir(name, version)) && !stub?(name, version)

def snapshot
  patterns = %w[subtest* sublib*].flat_map do |name|
    ["Cellar/#{name}/**/*", "opt/#{name}", "bin/#{name}", "var/homebrew/pinned/#{name}",
     "var/homebrew/linked/#{name}"]
  end
  patterns.flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH, base: PREFIX) }
          .reject { |path| DOT_ENTRIES.include?(File.basename(path)) }
          .to_h do |path|
            full = File.join(PREFIX, path)
            kind = if File.symlink?(full) then File.readlink(full)
            elsif File.directory?(full) then "directory"
            else "file"
            end
            [path, kind]
          end
end

def snapshot_diff(before, after)
  (before.keys | after.keys).filter_map do |path|
    "#{path}: #{before[path].inspect} -> #{after[path].inspect}" if before[path] != after[path]
  end.join("\n")
end

def check_unchanged(label, before)
  diff = snapshot_diff(before, snapshot)
  check "#{label} leaves the prefix unchanged", diff.empty?, diff
end

def reset
  FORMULAE.each_key { |name| @revisions[name] = 0 }
  write_formulae(PROBE_FORMULAE)
  originals = FORMULAE.keys.reject do |name|
    name.end_with?("-full", "-alt", "-v2", "-good") || name.include?("-user")
  end
  originals.each { |name| brew("substitute", "--remove", name, "--no-install") }
  brew("unpin", *FORMULAE.keys)
  brew("uninstall", "--force", "--ignore-dependencies", *FORMULAE.keys)
  leftovers = snapshot
  raise "The prefix still holds test formulae:\n#{leftovers.keys.join("\n")}" unless leftovers.empty?
end

def scenario(name)
  return if ONLY && name.exclude?(ONLY)

  puts "\n#{name}"
  @scenario = name
  reset
  yield
rescue => e
  check "runs without an error (#{e.class})", false, e.message
end

def set_up
  brew("untap", "--force", PROBE_TAP)
  @work = Dir.mktmpdir("substitute-test")
  make_archives
  source = File.join(@work, "probe-tap")
  write_formulae(File.join(source, "Formula"))
  git = ["git", "-C", source]
  system(*git, "init", "-q", "-b", "main", exception: true)
  system(*git, "add", "Formula", exception: true)
  system(*git, "-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "fixtures",
         exception: true)

  # Trust lives in $XDG_CONFIG_HOME/homebrew/trust.json, so a scratch directory keeps it off the real one.
  ENV["XDG_CONFIG_HOME"] = File.join(@work, "config")
  ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
  ENV["HOMEBREW_NO_ANALYTICS"] = "1"
  ENV["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
  ENV["HOMEBREW_NO_ENV_HINTS"] = "1"

  brew!("tap", PROBE_TAP, source)
  brew!("trust", "--tap", PROBE_TAP)
  FileUtils.mkdir_p(File.join(TAPS, TEST_USER))
  File.delete(TOOL_TAP_LINK) if File.symlink?(TOOL_TAP_LINK)
  File.symlink(REPO, TOOL_TAP_LINK)
  brew!("trust", "--command", "#{TEST_USER}/substitute/substitute")
  trust_other_copies
  loads = brew("substitute")
  raise "brew substitute does not load:\n#{loads.output}" unless loads.success?
end

# Brew can pick another tap's copy of the command, as in CI, where setup-homebrew installs this repository as a tap.
def trust_other_copies
  own = File.realpath(File.join(REPO, "cmd", "substitute.rb"))
  Dir.glob(File.join(TAPS, "*", "homebrew-*", "cmd", "substitute.rb")).each do |path|
    next if path.start_with?(TOOL_TAP_LINK)

    user, repo = path.delete_prefix("#{TAPS}/").split("/")
    if File.realpath(path) != own
      abort "#{user}/#{repo} provides a different `brew substitute`. Untap it, so that the tests run this code."
    end

    brew!("trust", "--command", "#{user}/#{repo.delete_prefix("homebrew-")}/substitute")
  end
end

def tear_down
  brew("uninstall", "--force", "--ignore-dependencies", *FORMULAE.keys)
  brew("untap", "--force", PROBE_TAP)
  File.delete(TOOL_TAP_LINK) if File.symlink?(TOOL_TAP_LINK)
  Dir.rmdir(File.join(TAPS, TEST_USER)) if Dir.empty?(File.join(TAPS, TEST_USER))
  FileUtils.remove_entry(@work) if @work
end

set_up

scenario "list with no substitutions" do
  result = brew("substitute")
  check_exit "list", result, 0
  check_output "list", result, "No substitutions."
end

scenario "list in a prefix with no Cellar" do
  cellar = File.join(PREFIX, "Cellar")
  aside = "#{cellar}.aside"
  raise "#{aside} exists" if File.exist?(aside)

  File.rename(cellar, aside) if File.directory?(cellar)
  begin
    result = brew("substitute")
    check_exit "list", result, 0
    check_output "list", result, "No substitutions."
  ensure
    File.rename(aside, cellar) if File.directory?(aside)
  end
end

scenario "swap, new dependent, remove" do
  brew!("install", "subtest", "subtest-user")
  before = snapshot

  dry_run = brew("substitute", "subtest-full", "--dry-run")
  check_exit "--dry-run", dry_run, 0
  check_output "--dry-run", dry_run, "Would create a stub keg for subtest 1.0 that points to subtest-full"
  check_unchanged "--dry-run", before

  swap = brew("substitute", "subtest-full")
  check_exit "swap", swap, 0
  marker = File.join(stub_dir("subtest", "1.0"), ".substituted-by")
  names_substitute = stub?("subtest", "1.0") && File.readlink(marker).end_with?("opt/subtest-full")
  check "the stub names the substitute", names_substitute, swap.output
  check "the original is pinned", pinned?("subtest")
  check "the stub replaces the real keg", !real_keg?("subtest", "1.0")
  check "the substitute is linked", linked?("subtest-full")
  check_output "list", brew("substitute"), "subtest -> subtest-full (1.0, ok)"

  repeat = brew("substitute", "subtest-full")
  check_exit "a repeated swap", repeat, 0
  check_output "a repeated swap", repeat, "already substituted"

  dependent = brew("install", "subtest-user2")
  check_exit "install of a new dependent", dependent, 0
  check "the new dependent does not install the original",
        dependent.output.exclude?("Installing dependencies") && !real_keg?("subtest", "1.0"), dependent.output

  removal = brew("substitute", "--remove", "subtest")
  check_exit "--remove", removal, 0
  check "--remove installs the real original", real_keg?("subtest", "1.0") && !stub?("subtest", "1.0")
  check "--remove unpins the original", !pinned?("subtest")
  check "--remove leaves the substitute linked and the original unlinked",
        linked?("subtest-full") && !linked?("subtest")
end

scenario "remove modes" do
  brew!("install", "subtest", "subtest-user")
  brew!("substitute", "subtest-full")
  substituted = snapshot

  dry_run = brew("substitute", "--remove", "--dry-run", "subtest")
  check_exit "--remove --dry-run", dry_run, 0
  check_unchanged "--remove --dry-run", substituted

  [
    ["--remove with --force", %w[--remove --force subtest], "mutually exclusive"],
    ["--remove with --refresh", %w[--remove --refresh subtest], "mutually exclusive"],
    ["--remove with --for", %w[--remove --for=subtest subtest], "mutually exclusive"],
    ["--remove without an original", %w[--remove], "Name at least one"],
    ["--no-install without --remove", %w[--no-install subtest], "valid only with --remove"],
    ["--remove for an original that is not substituted", %w[--remove subtest-user], "is not substituted"],
  ].each do |label, args, message|
    result = brew("substitute", *args)
    check_exit label, result, 1
    check_output label, result, message
    check_unchanged label, substituted
  end

  removal = brew("substitute", "--remove", "--no-install", "subtest")
  check_exit "--remove --no-install", removal, 0
  check "--remove --no-install removes the stub and the pin", !stub?("subtest", "1.0") && !pinned?("subtest")
  check "--remove --no-install leaves the substitute", File.symlink?(File.join(PREFIX, "opt", "subtest-full"))
  check "--remove --no-install does not install the original", !real_keg?("subtest", "1.0")
end

scenario "refusals" do
  brew!("install", "subtest", "subtest-user")
  before = snapshot

  [
    ["a version mismatch", %w[subtest-v2 --for=subtest], "cannot stand in for"],
    ["a name without -full and no --for", %w[subtest-v2], "Cannot infer the original"],
    ["--for with two substitutes", %w[subtest-full subtest-alt --for=subtest], "--for is valid with exactly one"],
  ].each do |label, args, message|
    result = brew("substitute", *args)
    check_exit label, result, 1
    check_output label, result, message
    check_unchanged label, before
  end

  brew!("pin", "subtest")
  pinned = snapshot
  [["a pinned original", %w[subtest-full]],
   ["a pinned original with --dry-run", %w[subtest-full --dry-run]]].each do |label, args|
    result = brew("substitute", *args)
    check_exit label, result, 1
    check_output label, result, "subtest is pinned"
    check_unchanged label, pinned
  end
  brew!("unpin", "subtest")

  brew!("substitute", "subtest-full")
  substituted = snapshot
  second = brew("substitute", "subtest-alt", "--for=subtest")
  check_exit "a second substitute for one original", second, 1
  check_output "a second substitute for one original", second, "already substituted by subtest-full"
  check_unchanged "a second substitute for one original", substituted
end

scenario "stale substitution and refresh" do
  brew!("install", "subtest", "subtest-user")
  brew!("substitute", "subtest-full")
  substituted = snapshot

  bump_revision("subtest")
  check_output "list", brew("substitute"), "subtest -> subtest-full (1.0, stale)"
  outdated = brew("outdated")
  # A tap formula prints with its tap name, as in `substitute-test/probe/subtest`.
  check "brew outdated lists the original", outdated.output.lines.any? { |line|
    line.split.first&.split("/")&.last == "subtest"
  },
        outdated.output

  blocked = brew("install", "subtest-user2")
  check_exit "install of a dependent while stale", blocked, 1
  check_output "install of a dependent while stale", blocked, "brew unpin"

  dry_run = brew("substitute", "--refresh", "--dry-run")
  check_exit "--refresh --dry-run", dry_run, 0
  check_output "--refresh --dry-run", dry_run, "Would re-point subtest from 1.0 to 1.0_1"
  check_unchanged "--refresh --dry-run", substituted

  refresh = brew("substitute", "--refresh")
  check_exit "--refresh", refresh, 0
  check_output "list", brew("substitute"), "subtest -> subtest-full (1.0_1, ok)"
  check "the stub and the pin follow the new version", stub?("subtest", "1.0_1") && pinned?("subtest") &&
                                                       !File.exist?(stub_dir("subtest", "1.0"))
  check_exit "install of a dependent after the refresh", brew("install", "subtest-user2"), 0
end

scenario "refresh waits for the substitute upgrade" do
  brew!("install", "subtest", "subtest-user")
  brew!("substitute", "subtest-full")
  bump_revision("subtest")
  bump_revision("subtest-full")
  stale = snapshot

  check_output "list", brew("substitute"), "(1.0, stale)"
  refusal = brew("substitute", "--refresh")
  check_exit "--refresh before the upgrade", refusal, 1
  check_output "--refresh before the upgrade", refusal, "brew upgrade subtest-full"
  check_unchanged "--refresh before the upgrade", stale

  brew!("upgrade", "subtest-full")
  check_exit "--refresh after the upgrade", brew("substitute", "--refresh"), 0
  check_output "list", brew("substitute"), "subtest -> subtest-full (1.0_1, ok)"
end

scenario "substitute-only revision shows behind" do
  brew!("install", "subtest", "subtest-user")
  brew!("substitute", "subtest-full")
  bump_revision("subtest-full")

  check_output "list", brew("substitute"), "subtest -> subtest-full (1.0, behind)"
  brew!("upgrade", "subtest-full")
  check_output "list after the upgrade", brew("substitute"), "subtest -> subtest-full (1.0, ok)"
end

scenario "library check" do
  library = MACOS ? "libsublib.dylib" : "libsublib.so"
  brew!("install", "sublib", "sublib-user", "sublib-full")
  before = snapshot

  dry_run = brew("substitute", "sublib-full", "--dry-run")
  check_exit "--dry-run", dry_run, 1
  check_output "--dry-run", dry_run, "Would fail"
  check_unchanged "--dry-run", before

  refusal = brew("substitute", "sublib-full")
  check_exit "a substitute without the library", refusal, 1
  check_output "a substitute without the library", refusal, library
  check "the original stays", real_keg?("sublib", "1.0") && !stub?("sublib", "1.0") && !pinned?("sublib")
  check_unchanged "a substitute without the library", before

  forced = brew("substitute", "sublib-full", "--force")
  check_exit "--force", forced, 1
  check_output "--force", forced, library
  check_unchanged "--force", before

  accepted = brew("substitute", "sublib-good", "--for=sublib")
  check_exit "a substitute with the library", accepted, 0
  check "the stub replaces the original", stub?("sublib", "1.0") && !real_keg?("sublib", "1.0"), accepted.output
end

tear_down

puts
if @failures.empty?
  puts "All scenarios passed."
else
  puts "#{@failures.length} failed:"
  puts @failures.map { |failure| "  #{failure}" }
  exit 1
end

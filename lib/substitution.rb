# typed: strict
# frozen_string_literal: true

require "formula"
require "formula_pin"
require "formulary"
require "keg"

# A substitution is a "stub keg": a real directory in the Cellar, named after
# the original formula, whose entries are symlinks into the substitute's opt
# prefix. Brew then sees the original as installed.
#
# The stub must be a real directory. A symlinked keg fails with "not a valid
# keg", and an `opt/<original>` link straight to the substitute's keg makes
# `brew uninstall <original>` delete the substitute.
module Substitution
  extend Utils::Output::Mixin

  MARKER = ".substituted-by"
  SKIPPED_ENTRIES = %w[INSTALL_RECEIPT.json sbom.spdx.json .brew].freeze
  UNDECLARED_HEADER = "Undeclared dependencies with linkage:"
  FINDING_HEADER = /\A[A-Z][^:]*:\z/ # https://regexper.com/#%5E%5BA-Z%5D%5B%5E%3A%5D*%3A%24
  FINDING_ENTRY = /\A\s+\S+\z/ # https://regexper.com/#%5E%5Cs%2B%5CS%2B%24
  private_constant :UNDECLARED_HEADER, :FINDING_HEADER, :FINDING_ENTRY

  # One installed stub keg: `original` is satisfied by `substitute` at `version`.
  class Stub < T::Struct
    const :original, String
    const :substitute, String
    const :version, String
    const :path, Pathname
  end

  class << self
    sig { returns(T::Array[Stub]) }
    def all
      return [] unless HOMEBREW_CELLAR.directory?

      HOMEBREW_CELLAR.children.select(&:directory?).flat_map do |rack|
        rack.children.filter_map do |version_dir|
          marker = version_dir/MARKER
          next unless marker.symlink?

          Stub.new(original:   rack.basename.to_s,
                   substitute: marker.readlink.basename.to_s,
                   version:    version_dir.basename.to_s,
                   path:       version_dir)
        end
      end
    end

    sig { params(original_name: String).returns(T.nilable(Stub)) }
    def find(original_name)
      all.find { |stub| stub.original == original_name }
    end

    sig { params(stub: Stub).returns(Symbol) }
    def status(stub)
      return :dangling unless (HOMEBREW_PREFIX/"opt"/stub.substitute).exist?

      current_version = Formulary.factory(stub.original).pkg_version.to_s
      return :stale if stub.version != current_version

      behind?(Formulary.factory(stub.substitute)) ? :behind : :ok
    rescue FormulaUnavailableError
      :unknown
    end

    # The formula file names a newer version than the installed keg. This is the
    # state after `brew update` and before `brew upgrade`.
    sig { params(substitute: Formula).returns(T::Boolean) }
    def behind?(substitute)
      substitute.any_version_installed? && !substitute.latest_version_installed?
    end

    # Read-only. Finds libraries that a dependent loads through the original
    # and that the substitute does not ship. Returns the missing paths under
    # `opt/<substitute>`, keyed by dependent name.
    sig {
      params(original: Formula, substitute: Formula,
             dependents: T::Array[Formula]).returns(T::Hash[String, T::Array[String]])
    }
    def missing_libraries(original, substitute, dependents)
      missing = T.let({}, T::Hash[String, T::Array[String]])
      dependents.each do |dependent|
        keg = dependent.any_installed_keg
        next unless keg

        names = keg.binary_executable_or_library_files.flat_map do |file|
          file.dynamically_linked_libraries(except: :DYLIB_USE_WEAK_LINK)
        end
        gone = names.uniq.filter_map { |name| substitute_path(original, substitute, name) }.reject(&:exist?)
        missing[dependent.name] = gone.map(&:to_s) unless gone.empty?
      end
      missing
    end

    # An `Error:` line means that the run stopped early, so later dependents were not tested.
    sig { params(output: String, substitute_names: T::Array[String]).returns(T::Boolean) }
    def only_substitute_undeclared?(output, substitute_names)
      lines = output.lines(chomp: true)
      return false if lines.any? { |line| line.start_with?("Error:") }
      return false if lines.grep(FINDING_HEADER).uniq != [UNDECLARED_HEADER]

      lines.grep(FINDING_ENTRY).map(&:strip).all? { |name| substitute_names.include?(name) }
    end

    # Exit status 1 is how `brew linkage --test` reports a finding. A killed run has another status or none, and it
    # tested only some dependents.
    sig { params(code: T.nilable(Integer), output: String, names: T::Array[String]).returns(T::Boolean) }
    def expected_linkage_failure?(code, output, names)
      code == 1 && only_substitute_undeclared?(output, names)
    end

    sig { params(original: Formula).returns(T::Array[Keg]) }
    def real_kegs(original)
      original.installed_kegs.reject { |keg| (Pathname(keg.to_s)/MARKER).symlink? }
    end

    sig { params(original: Formula, substitute: Formula).returns(Stub) }
    def create(original, substitute)
      stub_dir = original.rack/original.pkg_version.to_s
      existed = stub_dir.exist?
      stub_dir.mkpath
      begin
        substitute.opt_prefix.children.each do |entry|
          next if SKIPPED_ENTRIES.include?(entry.basename.to_s)

          (stub_dir/entry.basename).make_relative_symlink(entry)
        end
        (stub_dir/MARKER).make_relative_symlink(substitute.opt_prefix)
        Keg.new(stub_dir).optlink
        FormulaPin.new(original).pin
      rescue StandardError, Interrupt
        discard(original, stub_dir) unless existed
        raise
      end
      Stub.new(original: original.name, substitute: substitute.name, version: stub_dir.basename.to_s, path: stub_dir)
    end

    sig { params(stub: Stub).void }
    def remove(stub)
      discard(Formulary.factory(stub.original), stub.path)
    end

    sig { params(args: String).void }
    def brew(*args)
      SystemCommand.safe_system(HOMEBREW_BREW_FILE, *args)
    end

    # A linked substitute owns the same files as the original, so it must be
    # unlinked while the original installs. Afterwards each formula gets the
    # link state that the caller recorded before it changed anything.
    sig {
      params(original: Formula, substitute: T.nilable(Formula), original_linked: T::Boolean,
             substitute_linked: T::Boolean).void
    }
    def reinstall_original(original, substitute, original_linked:, substitute_linked:)
      brew("unlink", substitute.full_name) if substitute&.linked?
      begin
        install_original(original)
        brew("unlink", original.full_name) unless original_linked
      ensure
        brew("link", "--force", substitute.full_name) if substitute_linked && substitute
      end
    end

    private

    sig { params(original: Formula).void }
    def install_original(original)
      brew("install", original.full_name)
    rescue ErrorDuringExecution, Interrupt
      opoo "The install of #{original.name} did not finish. Run `brew install #{original.full_name}` to install it."
      raise
    end

    sig { params(original: Formula, path: Pathname).void }
    def discard(original, path)
      FormulaPin.new(original).unpin
      Keg.new(path).uninstall(raise_failures: true)
    end

    # Maps a library name under the original (`opt/<original>/...` or
    # `Cellar/<original>/<version>/...`) to the same path under the substitute.
    sig { params(original: Formula, substitute: Formula, name: String).returns(T.nilable(Pathname)) }
    def substitute_path(original, substitute, name)
      opt_prefix = "#{original.opt_prefix}/"
      rack = "#{original.rack}/"
      relative = if name.start_with?(opt_prefix)
        name.delete_prefix(opt_prefix)
      elsif name.start_with?(rack)
        name.delete_prefix(rack).split("/", 2)[1]
      end
      relative && (substitute.opt_prefix/relative)
    end
  end
end

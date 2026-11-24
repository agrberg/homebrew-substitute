# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "open3"
require_relative "../lib/substitution"

module Homebrew
  module Cmd
    # Implements `brew substitute`.
    class Substitute < AbstractCommand
      cmd_args do
        usage_banner "`substitute` [<options>] [<substitute>|<original> ...]"
        description <<~EOS
          Use an installed <substitute> formula to satisfy dependencies on its original formula.
          The original is the <substitute> name without `-full`, unless `--for` names it.
          With no arguments, list the current substitutions.
          With `--remove`, the arguments are originals. Remove their substitutions and install the originals again.
          This is an unsupported local change. Undo it with `brew substitute --remove`.
        EOS
        flag   "--for=",
               description: "Name the original formula. Valid with exactly one <substitute>."
        switch "-n", "--dry-run",
               description: "Print the steps and change nothing."
        switch "--force",
               description: "Skip the version check, the outdated <substitute> check, and the dependency warning."
        switch "--refresh",
               description: "Re-point stale substitutions to the current version of the original."
        switch "--remove",
               description: "Remove the substitution for each <original>. Install the original again."
        switch "--no-install",
               description: "With `--remove`, do not install the original again."
        conflicts "--refresh", "--for"
        conflicts "--remove", "--refresh"
        conflicts "--remove", "--for"
        conflicts "--remove", "--force"

        named_args :formula
      end

      sig { override.void }
      def run
        odie "--no-install is valid only with --remove." if args.no_install? && !args.remove?

        if args.remove?
          odie "Name at least one <original> to remove." if args.named.empty?
          args.named.to_formulae.each { |original| remove(original) }
        elsif args.refresh?
          refresh
        elsif args.named.empty?
          list
        else
          formulae = args.named.to_formulae
          odie "--for is valid with exactly one <substitute>." if args.for && formulae.length != 1
          formulae.each { |substitute| swap(substitute, original_name_for(substitute)) }
        end
      end

      private

      sig { params(substitute: Formula).returns(String) }
      def original_name_for(substitute)
        return args.for if args.for

        original_name = substitute.name.delete_suffix("-full")
        if original_name == substitute.name
          odie "Cannot infer the original of #{substitute.name}. Pass --for=<original>."
        end

        original_name
      end

      sig { params(original: Formula).void }
      def remove(original)
        stub = Substitution.find(original.name)
        odie "#{original.name} is not substituted." unless stub

        if args.dry_run?
          ohai "Would remove the substitution for #{original.name}"
          ohai "Would install #{original.name}" unless args.no_install?
          return
        end

        substitute = begin
          Formulary.factory(stub.substitute)
        rescue FormulaUnavailableError
          nil
        end

        ohai "Removing the substitution for #{original.name}"
        Substitution.remove(stub)
        return if args.no_install?

        substitute_linked = substitute&.linked? || false
        Substitution.reinstall_original(original, substitute, original_linked: !substitute_linked, substitute_linked:)
      end

      sig { void }
      def list
        stubs = Substitution.all
        return puts "No substitutions." if stubs.empty?

        stubs.each do |stub|
          puts "#{stub.original} -> #{stub.substitute} (#{stub.version}, #{Substitution.status(stub)})"
        end
      end

      sig { void }
      def refresh
        stale = Substitution.all.select { |stub| Substitution.status(stub) == :stale }
        return ohai "No stale substitutions." if stale.empty?

        pairs = stale.map { |stub| [stub, Formulary.factory(stub.original), Formulary.factory(stub.substitute)] }
        # Every read-only check runs before the first change, so one refusal leaves all stubs as they were.
        pairs.each do |_stub, original, substitute|
          check_compatible(original, substitute)
          check_libraries(original, substitute, original.runtime_installed_formula_dependents,
                          args.dry_run? ? "Would fail" : "Cannot refresh")
        end

        # The checks above must all pass before the first change.
        pairs.each do |stub, original, substitute| # rubocop:disable Style/CombinableLoops
          next ohai "Would re-point #{original.name} from #{stub.version} to #{original.pkg_version}" if args.dry_run?

          Substitution.remove(stub)
          begin
            Substitution.create(original, substitute)
          rescue StandardError, Interrupt
            opoo "#{original.name} has no substitution now. " \
                 "Run `brew substitute #{substitute.name} --for=#{original.name}` to create it."
            raise
          end
          ohai "Re-pointed #{original.name} to #{original.pkg_version}"
        end
      end

      sig { params(original: Formula, substitute: Formula).void }
      def check_compatible(original, substitute)
        return if args.force?

        if Substitution.behind?(substitute)
          odie <<~EOS
            #{substitute.name} #{substitute.any_installed_version} is installed, but its formula is at #{substitute.pkg_version}.
            The stub would name a version that the installed #{substitute.name} does not have.
            Run `brew upgrade #{substitute.name}` first. Pass --force to continue.
          EOS
        end

        if original.version != substitute.version
          odie <<~EOS
            #{substitute.name} #{substitute.version} cannot stand in for #{original.name} #{original.version}.
            A different version can change library names. Pass --force to continue.
          EOS
        end

        missing = original.runtime_dependencies(read_from_tab: false).map(&:name) -
                  substitute.runtime_dependencies(read_from_tab: false).map(&:name)
        return if missing.empty?

        opoo "#{substitute.name} does not depend on: #{missing.join(", ")}"
      end

      sig { params(substitute: Formula, original_name: String).void }
      def swap(substitute, original_name)
        original = Formulary.factory(original_name)
        odie "#{original.name} and #{substitute.name} are the same formula." if original.name == substitute.name
        refuse_other_substitute(original, substitute)
        if Substitution.find(original.name)
          return ohai "#{original.name} is already substituted by #{substitute.name}."
        end

        refuse_pinned(original)
        check_compatible(original, substitute)
        dependents = original.runtime_installed_formula_dependents
        if args.dry_run?
          ohai "Would install #{substitute.name}" unless substitute.any_version_installed?
          unless Substitution.real_kegs(original).empty?
            ohai "Would uninstall #{original.name} with --ignore-dependencies"
          end
          ohai "Would create a stub keg for #{original.name} #{original.pkg_version} " \
               "that points to #{substitute.name}"
          ohai "Would pin #{original.name}"
          ohai "Would link #{substitute.name}"
          ohai "Would run `brew linkage --test` on the dependents of #{original.name}"
          if substitute.any_version_installed?
            check_libraries(original, substitute, dependents, "Would fail")
          else
            opoo "Cannot check the libraries of #{substitute.name} until it is installed."
          end
          return
        end

        real_kegs = Substitution.real_kegs(original)
        original_linked = real_kegs.any?(&:linked?)
        substitute_linked = substitute.linked?
        Substitution.brew("install", substitute.full_name) unless substitute.any_version_installed?
        check_libraries(original, substitute, dependents, "Cannot substitute")

        # Everything from the uninstall on is inside the rescue, so an error or Ctrl-C rolls back.
        begin
          Substitution.brew("uninstall", "--ignore-dependencies", original.full_name) unless real_kegs.empty?
          unless Substitution.real_kegs(original).empty?
            raise "#{original.name} is still installed after the uninstall."
          end

          ohai "Substituting #{substitute.name} for #{original.name}"
          Substitution.create(original, substitute)
          link(substitute)
          return if linkage_ok?(dependents, substitute)

          opoo "The linkage test failed. Rolling back."
        rescue StandardError, Interrupt => e
          reason = e.message.strip.delete_suffix(".").presence || e.class
          opoo "The substitution failed (#{reason}). Rolling back."
          roll_back(original, substitute, real_kegs, original_linked:, substitute_linked:)
          raise
        end

        roll_back(original, substitute, real_kegs, original_linked:, substitute_linked:)
        odie "The substitution was rolled back."
      end

      # `brew uninstall` exits 0 for a pinned formula and removes nothing, so the swap would go on with the real keg.
      sig { params(original: Formula).void }
      def refuse_pinned(original)
        return unless original.pinned?

        odie "#{original.name} is pinned. Run `brew unpin #{original.name}` first. Nothing was changed."
      end

      sig { params(original: Formula, substitute: Formula).void }
      def refuse_other_substitute(original, substitute)
        existing = Substitution.find(original.name)
        return if existing.nil? || existing.substitute == substitute.name

        odie "#{original.name} is already substituted by #{existing.substitute}. " \
             "Run `brew substitute --remove #{original.name}` first."
      end

      # Restores the state from before the uninstall in `swap`. Without a real original, only the substitute's
      # link state and the stub need to change.
      sig {
        params(original: Formula, substitute: Formula, real_kegs: T::Array[Keg], original_linked: T::Boolean,
               substitute_linked: T::Boolean).void
      }
      def roll_back(original, substitute, real_kegs, original_linked:, substitute_linked:)
        stub = Substitution.find(original.name)
        Substitution.remove(stub) if stub
        if real_kegs.empty?
          Substitution.brew("unlink", substitute.full_name) if !substitute_linked && substitute.linked?
        else
          Substitution.reinstall_original(original, substitute, original_linked:, substitute_linked:)
        end
      end

      # Read-only. Needs the substitute on disk, because the check looks for files under its opt prefix.
      sig { params(original: Formula, substitute: Formula, dependents: T::Array[Formula], verdict: String).void }
      def check_libraries(original, substitute, dependents, verdict)
        missing = Substitution.missing_libraries(original, substitute, dependents)
        return if missing.empty?

        lines = missing.flat_map { |dependent, paths| paths.map { |path| "  #{dependent}: #{path}" } }
        odie <<~EOS
          #{verdict}: #{substitute.name} lacks libraries that dependents of #{original.name} load.
          #{lines.join("\n")}
          Nothing was removed or replaced.
        EOS
      end

      sig { params(substitute: Formula).void }
      def link(substitute)
        return if substitute.linked?

        Substitution.brew("link", "--force", substitute.full_name)
      rescue ErrorDuringExecution
        opoo "Could not link #{substitute.name}. Fix the conflict, then run `brew link --force #{substitute.name}`."
      end

      # `Substitution.brew` raises on failure. This check needs the exit status as a boolean.
      # Homebrew `master` since 23 Nov 2026 (commit eb09617, after the 7.0.16 release) makes `brew linkage --test`
      # fail on an undeclared dependency. A dependent that linked the library of its original now links the
      # substitute, so that one finding is expected.
      sig { params(dependents: T::Array[Formula], substitute: Formula).returns(T::Boolean) }
      def linkage_ok?(dependents, substitute)
        return true if dependents.empty?

        output = +""
        command = [HOMEBREW_BREW_FILE.to_s, "linkage", "--test", *dependents.map(&:full_name)]
        # On a user's first developer command, brew prints a notice that looks like a finding. This variable stops it.
        status = Open3.popen2e({ "HOMEBREW_DEV_CMD_RUN" => "1" }, *command) do |stdin, lines, thread|
          stdin.close
          lines.each_line do |line|
            print line
            output << line
          end
          thread.value
        end
        return true if status.success?

        substitute_names = [substitute.name, substitute.full_name]
        expected = Substitution.expected_linkage_failure?(status.exitstatus, output, substitute_names)
        return false unless expected

        ohai "The linkage test lists #{substitute.name} as an undeclared dependency. This is expected, so the " \
             "substitution stays."
        true
      end
    end
  end
end
